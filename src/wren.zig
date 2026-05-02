pub const VirtualMachine = @This();
pub const std = @import("std");
pub const Allocator = std.mem.Allocator;
// const c = @import("c");
const c = @import("wren_c.zig");

pub const RawVM = c.WrenVM;

/// A nullable pointer to a WrenHandle (class, method, or object reference).
pub const Handle = ?*c.WrenHandle;

const Error = error{
    /// Equivalent to `WREN_RESULT_COMPILE_ERROR`.
    CompileError,

    /// Equivalent to `WREN_RESULT_RUNTIME_ERROR`.
    RuntimeError,

    /// Function called without first calling `VirtualMachine.init`.
    VirutalMachineIsUninitialized,

    FailedToCreateWrenVM,
    FailedToCreateModule,

    /// Returned when `wrenGetVariable` finds no matching variable in the given module.
    VariableDoesNotExist,

    /// Slot type doesn't match a supported Zig type in `getSlot`/`setSlot`.
    InvalidType,

    ImportsUnsupported,
};

/// Configuration passed to `VirtualMachine.init`.
/// Unset optional function pointers disable the corresponding Wren feature.
pub const Configuration = struct {
    /// Called by Wren when it needs to load a module by name. Return null to signal failure.
    load_module_fn: ?*const fn (c_vm: ?*c.WrenVM, module_name: []const u8) ?[]const u8 = null,

    /// Called after a module has finished loading, for cleanup or caching.
    load_module_complete_fn: ?*const fn (c_vm: ?*c.WrenVM, module_name: []const u8, src: []const u8) void = null,

    writeFn: c.WrenWriteFn = null,
    errorFn: c.WrenErrorFn = null,
    initialHeapSize: i32 = 1024 * 1024 * 10,
    minHeapSize: i32 = 1024 * 1024,
    heapGrowthPercent: i32 = 50,

    /// Arbitrary user data pointer threaded through VMContext, accessible via `userData`.
    userData: ?*anyopaque = null,
};

/// A resolved handle to a Wren method signature, ready to be called via `call` or `callStatic`.
pub const Method = struct {
    /// Handle
    handle: *c.WrenHandle,

    /// Number of arguments EXCLUDING the receiver (`self`).
    argc: u32,

    /// Creates a call handle for `method_name` with `argc` parameters (excluding receiver).
    /// Comptime-builds the Wren signature string, e.g. `argc=2` -> `"myFunc(_,_)"`.
    pub fn init(wren: VirtualMachine, comptime method_name: []const u8, comptime argc: u32) !Method {
        // Append '_,' for class and each argument
        const signature: [:0]const u8 = blk: {
            comptime var sig: []const u8 = method_name ++ "(";
            inline for (0..argc) |i| {
                if (i > 0) sig = sig ++ ",";
                sig = sig ++ "_";
            }
            sig = sig ++ ")";
            break :blk (sig ++ "\x00")[0..sig.len :0];
        };

        if (c.wrenMakeCallHandle(wren.vm, signature)) |handle| {
            return Method{ .handle = handle, .argc = argc };
        } else {
            return Error.VariableDoesNotExist;
        }
    }

    pub fn deinit(self: *Method, wren: VirtualMachine) void {
        c.wrenReleaseHandle(wren.vm, self.handle);
    }
};

/// Wrapper around Class `WrenHandle`.
pub const Class = struct {
    /// Name of class
    name: [:0]const u8,

    /// `WrenHandle` to Class.
    handle: *c.WrenHandle,

    pub fn init(comptime module: [*c]const u8, wren: VirtualMachine, name: [:0]const u8) !Class {
        // Find class via name
        c.wrenEnsureSlots(wren.vm, 1);

        c.wrenGetVariable(wren.vm, module, name, 0);

        if (c.wrenGetSlotHandle(wren.vm, 0)) |handle| {
            return .{ .name = name, .handle = handle };
        } else {
            return Error.VariableDoesNotExist;
        }
    }

    pub fn deinit(self: *Class, wren: VirtualMachine) void {
        c.wrenReleaseHandle(wren.vm, self.handle);
    }
};

fn writeFn(_: ?*c.WrenVM, text: [*c]const u8) callconv(.c) void {
    std.debug.print("{s}", .{text});
}

fn errorFn(
    c_vm: ?*c.WrenVM,
    error_type: c.WrenErrorType,
    module: [*c]const u8,
    line: c_int,
    message: [*c]const u8,
) callconv(.c) void {
    const ptr = c.wrenGetUserData(c_vm) orelse return;

    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));
    vm_context.err = error_type;

    const blank: [*c]const u8 = "";
    std.log.err("[{s} line {}]({}) {s}\n", .{
        module orelse blank,
        line,
        error_type,
        message orelse blank,
    });
}

fn bindForeignClassFn(c_vm: ?*c.WrenVM, module: [*c]const u8, className: [*c]const u8) callconv(.c) c.WrenForeignClassMethods {
    const ptr = c.wrenGetUserData(c_vm) orelse return .{};
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));

    // TODO:: Take in as max module and class name
    var buf: [256]u8 = [_]u8{0} ** 256;
    const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{
        std.mem.span(module),
        std.mem.span(className),
    }) catch return .{};

    if (vm_context.foreign_methods.get(key)) |method| {
        return .{ .allocate = method };
    } else {
        std.log.err("No class defined with `{s}` found in the ff:", .{key});
        var iterator = vm_context.foreign_methods.iterator();
        while (iterator.next()) |it| {
            const k = it.key_ptr.*;
            std.log.debug(" - `{s}`", .{k});
        }
        return .{};
    }
}

fn bindForeignMethodFn(
    c_vm: ?*c.WrenVM,
    module: [*c]const u8,
    className: [*c]const u8,
    isStatic: bool,
    signature: [*c]const u8,
) callconv(.c) c.WrenForeignMethodFn {
    _ = isStatic;

    const ptr = c.wrenGetUserData(c_vm) orelse return null;
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));

    // TODO:: Take in as max
    var buf: [256]u8 = [_]u8{0} ** 256;
    const key = std.fmt.bufPrint(&buf, "{s}.{s}.{s}", .{
        std.mem.span(module),
        std.mem.span(className),
        std.mem.span(signature),
    }) catch return null;

    if (vm_context.foreign_methods.get(key)) |method| {
        return method;
    } else {
        std.log.err("No method with sig `{s}` found in the ff:", .{key});
        var iterator = vm_context.foreign_methods.iterator();
        while (iterator.next()) |it| {
            const k = it.key_ptr.*;
            std.log.debug(" - `{s}`", .{k});
        }
        return null;
    }
}

fn loadModuleCompleteFn(c_vm: ?*c.WrenVM, name: [*c]const u8, result: c.struct_WrenLoadModuleResult) callconv(.c) void {
    const ptr = c.wrenGetUserData(c_vm) orelse return;
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));

    if (vm_context.load_module_complete_fn) |complete| {
        complete(c_vm, std.mem.span(name), std.mem.span(result.source));
    }
}

fn loadModuleFn(c_vm: ?*c.WrenVM, name: [*c]const u8) callconv(.c) c.WrenLoadModuleResult {
    const ptr = c.wrenGetUserData(c_vm) orelse return .{};
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));

    if (vm_context.load_module_fn) |load| {
        return .{
            .onComplete = loadModuleCompleteFn,
            .source = if (load(c_vm, std.mem.span(name))) |src| src.ptr else null,
        };
    }

    @panic("Modules unsupported!");
}

/// Stored in Wren's `userData` pointer so the single slot can carry both foreign-method
/// bindings and the caller's own user data pointer.
const VMContext = struct {
    /// Lookup table for foreign class allocators and method fns, keyed by "module.Class[.sig]".
    foreign_methods: std.StringHashMap(c.WrenForeignMethodFn),

    /// User-supplied module loader; called once per unresolved import.
    load_module_fn: ?*const fn (c_vm: ?*c.WrenVM, module_name: []const u8) ?[]const u8,

    /// User-supplied post-load hook; called after a module source is consumed.
    load_module_complete_fn: ?*const fn (c_vm: ?*c.WrenVM, module_name: []const u8, src: []const u8) void,

    /// Last Wren error type recorded by `errorFn`; null if no error has occurred.
    err: ?c.WrenErrorType,

    /// Pass-through pointer from `Configuration.userData`, untouched by the VM wrapper.
    user_data: ?*anyopaque,
};

/// Underlying `WrenVM` pointer.
vm: *c.WrenVM,

/// Initialises the VM with the given config, allocating a `VMContext` on `gpa`.
/// Call `deinit` to free resources.
pub fn init(gpa: Allocator, conf: Configuration) !VirtualMachine {
    var config: c.WrenConfiguration = .{};
    c.wrenInitConfiguration(&config);

    config.heapGrowthPercent = conf.heapGrowthPercent;
    config.writeFn = writeFn;
    config.errorFn = errorFn;
    config.bindForeignMethodFn = bindForeignMethodFn;
    config.bindForeignClassFn = bindForeignClassFn;
    config.loadModuleFn = loadModuleFn;

    // Allocate vm context and store passed user ptr
    const vm_context = try gpa.create(VMContext);
    vm_context.* = .{
        .foreign_methods = .init(gpa),
        .user_data = conf.userData,
        .load_module_fn = conf.load_module_fn,
        .load_module_complete_fn = conf.load_module_complete_fn,
        .err = null,
    };

    // Pass vm context as actual user data
    config.userData = vm_context;

    if (c.wrenNewVM(&config)) |vm| {
        return .{ .vm = vm };
    } else {
        return Error.FailedToCreateWrenVM;
    }
}

/// Frees the VMContext and the underlying WrenVM.
/// All `Class` and `Method` handles must be released before calling this.
pub fn deinit(self: *VirtualMachine, gpa: Allocator) void {
    if (c.wrenGetUserData(self.vm)) |ptr| {
        const vm_context: *VMContext = @ptrCast(@alignCast(ptr));
        vm_context.foreign_methods.deinit();
        gpa.destroy(vm_context);
    }
    c.wrenFreeVM(self.vm);
}

/// Wraps a raw C `WrenVM*` without taking ownership. Useful inside foreign method callbacks.
pub fn fromRaw(c_vm: *c.WrenVM) VirtualMachine {
    return .{ .vm = c_vm };
}

/// Returns the caller's user data pointer, or null if the VM has no context.
pub fn userData(self: *VirtualMachine) ?*anyopaque {
    const ptr = c.wrenGetUserData(self.vm) orelse return null;
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));
    return vm_context.user_data;
}

/// Replaces the caller's user data pointer inside the VMContext.
pub fn setUserData(self: *VirtualMachine, data: *anyopaque) void {
    const ptr = c.wrenGetUserData(self.vm) orelse return;
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));
    vm_context.user_data = data;
}

/// Registers foreign methods for a class in a module.
///
/// Each entry in `methods` is `{ .sig, .method, .finalizer, .flags }`.
/// An empty `sig` registers the entry as the class allocator (constructor).
///
/// Example:
/// ```zig
/// try vm.bindForeignMethods("mymod", "Vec2", &.{
///     .{ .sig = "",         .method = vec2Alloc, .flags = .{ .allocate = true } },
///     .{ .sig = "add(_,_)", .method = vec2Add,   .flags = .{} },
/// });
/// ```
pub fn bindForeignMethods(
    self: *VirtualMachine,
    comptime module: []const u8,
    comptime class: []const u8,
    comptime methods: []const struct {
        /// Method signture.
        sig: []const u8 = "",

        /// Foreign fn.
        method: c.WrenForeignMethodFn = null,
        finalzer: c.WrenFinalizerFn = null,

        /// Flags
        flags: struct {
            allocate: bool = false,
            finalize: bool = false,
        },
    },
) !void {
    const ptr = c.wrenGetUserData(self.vm) orelse return Error.VirutalMachineIsUninitialized;
    const vm_context: *VMContext = @ptrCast(@alignCast(ptr));

    inline for (methods) |m| {
        // Constructor
        if (m.sig.len == 0) {
            const key = module ++ "." ++ class;
            try vm_context.foreign_methods.put(key, m.method);
            continue;
        }

        const key = module ++ "." ++ class ++ "." ++ m.sig;
        try vm_context.foreign_methods.put(key, m.method);
    }
}

/// Reads slot `slot` as type `T`. Supported types: f64/f32, i32/u32, `[]const u8`.
pub fn getSlot(self: *VirtualMachine, comptime T: type, slot: i32) !T {
    return @as(T, switch (T) {
        f64, f32, comptime_float => @floatCast(c.wrenGetSlotDouble(self.vm, slot)),
        i32, comptime_int => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
        u32 => @intFromFloat(c.wrenGetSlotDouble(self.vm, slot)),
        []const u8 => std.mem.span(c.wrenGetSlotString(self.vm, slot)),
        else => return Error.InvalidType,
    });
}

/// Returns a typed pointer to the foreign object data stored in `slot`
pub fn getSlotForeign(self: *VirtualMachine, comptime T: type, slot: i32) !*T {
    if (c.wrenGetSlotForeign(self.vm, slot)) |data| {
        const instance: *T = @ptrCast(@alignCast(data));
        return instance;
    }

    return Error.VariableDoesNotExist;
}

/// Writes a value into `slot`. Supported types: f64/f32, i32/u32
pub fn setSlot(self: *VirtualMachine, val: anytype, slot: i32) !void {
    const T = @TypeOf(val);
    switch (@TypeOf(val)) {
        bool => c.wrenSetSlotBool(self.vm, slot, val),
        f64, f32, comptime_float => c.wrenSetSlotDouble(self.vm, slot, @floatCast(val)),
        u32, i32, comptime_int => c.wrenSetSlotDouble(self.vm, slot, @floatFromInt(val)),
        else => switch (@typeInfo(T)) {
            // Catches [:0]const u8, []const u8, [*:0]const u8, and *const [N:0]u8
            .pointer => c.wrenSetSlotString(self.vm, slot, @ptrCast(val)),
            else => return Error.InvalidType,
        },
    }
}

/// Allocates a new Wren foreign object of `T`'s size in slot 0 and writes `val` into it.
/// Must be called from within a foreign class allocator.
pub fn newForeign(self: *VirtualMachine, val: anytype) !void {
    const T = @TypeOf(val);
    if (c.wrenSetSlotNewForeign(self.vm, 0, 0, @sizeOf(T))) |data| {
        const instance: *T = @ptrCast(@alignCast(data));
        instance.* = val;
    }
}

/// Compiles and runs `src_code` inside `module`.
pub fn interpret(self: *VirtualMachine, comptime module: anytype, src_code: [:0]const u8) !void {
    const result = c.wrenInterpret(self.vm, module, src_code);

    switch (result) {
        c.WREN_RESULT_COMPILE_ERROR => return Error.CompileError,
        c.WREN_RESULT_RUNTIME_ERROR => return Error.RuntimeError,
        c.WREN_RESULT_SUCCESS => {},
        else => unreachable,
    }
}

/// Calls a static method on `class` with the given `args` tuple.
/// `args` length must equal `method.argc`.
pub fn callStatic(self: *VirtualMachine, class: Class, method: Method, args: anytype) !void {
    const Args = @TypeOf(args);
    const args_struct = @typeInfo(Args).@"struct";
    const fields = args_struct.fields;

    // Fields count must equal method argc
    std.debug.assert(fields.len == method.argc);

    // Set slot 0 to class handle
    c.wrenEnsureSlots(self.vm, fields.len + 1);
    c.wrenSetSlotHandle(self.vm, 0, class.handle);

    // Set each argument to 1 + n
    var arg_counter: usize = 1;
    inline for (fields) |field| {
        switch (field.type) {
            f64, f32, comptime_float => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            i32, comptime_int => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            else => return Error.InvalidType,
        }

        arg_counter += 1;
    }

    // Invoke on vm
    return switch (c.wrenCall(self.vm, method.handle)) {
        c.WREN_RESULT_COMPILE_ERROR => Error.CompileError,
        c.WREN_RESULT_RUNTIME_ERROR => Error.RuntimeError,
        else => {},
    };
}

/// Calls `constructor` on `class` and returns a pinned handle to the new instance.
/// Caller is responsible for releasing the handle with `wrenReleaseHandle`.
pub fn new(self: *VirtualMachine, class: Class, constructor: Method, args: anytype) !Handle {
    const Args = @TypeOf(args);
    const args_struct = @typeInfo(Args).@"struct";
    const fields = args_struct.fields;

    // Fields count must equal method argc
    std.debug.assert(fields.len == constructor.argc);

    // Set slot 0 to class handle
    c.wrenEnsureSlots(self.vm, fields.len + 1);
    c.wrenSetSlotHandle(self.vm, 0, class.handle);

    // Set each argument to 1 + n
    var arg_counter: usize = 1;
    inline for (fields) |field| {
        switch (field.type) {
            f64, f32, comptime_float => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            i32, comptime_int => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            else => return Error.InvalidType,
        }

        arg_counter += 1;
    }

    // Invoke on vm
    return switch (c.wrenCall(self.vm, constructor.handle)) {
        c.WREN_RESULT_COMPILE_ERROR => Error.CompileError,
        c.WREN_RESULT_RUNTIME_ERROR => Error.RuntimeError,
        else => c.wrenGetSlotHandle(self.vm, 0),
    };
}

/// Calls `method` on an existing `object` handle with the given `args` tuple.
pub fn call(self: *VirtualMachine, object: Handle, method: Method, args: anytype) !void {
    const Args = @TypeOf(args);
    const args_struct = @typeInfo(Args).@"struct";
    const fields = args_struct.fields;

    // Fields count must equal method argc
    std.debug.assert(fields.len == method.argc);

    // Set slot 0 to class handle
    c.wrenEnsureSlots(self.vm, fields.len + 1);
    c.wrenSetSlotHandle(self.vm, 0, object);

    // Set each argument to 1 + n
    var arg_counter: usize = 1;
    inline for (fields) |field| {
        switch (field.type) {
            f64, f32, comptime_float => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            i32, comptime_int => c.wrenSetSlotDouble(self.vm, @intCast(arg_counter), @field(args, field.name)),
            else => return Error.InvalidType,
        }

        arg_counter += 1;
    }

    // Invoke on vm
    return switch (c.wrenCall(self.vm, method.handle)) {
        c.WREN_RESULT_COMPILE_ERROR => Error.CompileError,
        c.WREN_RESULT_RUNTIME_ERROR => Error.RuntimeError,
        else => {},
    };
}
