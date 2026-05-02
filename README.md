# zwren

A Zig wrapper around the [Wren](https://wren.io) scripting language.

## Requirements

- Zig `0.17.0-dev` or later

## Adding to your project

```sh
zig fetch --save git+https://github.com/MokaHiko/zwren
```

Then in your `build.zig`:

```zig
const zwren = b.dependency("zwren", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zwren", zwren.module("zwren"));
```

## Quick start

```zig
const std = @import("std");
const zwren = @import("zwren");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var vm = try zwren.VirtualMachine.init(gpa.allocator(), .{});
    defer vm.deinit(gpa.allocator());

    try vm.interpret("main",
        \\ System.print("Hello from Wren!")
    );
}
```

## Usage

### Interpreting Wren source

```zig
try vm.interpret("main", "System.print(\"hi\")");
```

### Calling a static method from Zig

```zig
// Wren: class Math { static add(a, b) { return a + b } }
var math_class = try zwren.Class.init("main", vm, "Math");
defer math_class.deinit(vm);

var add = try zwren.Method.init(vm, "add", 2);
defer add.deinit(vm);

try vm.callStatic(math_class, add, .{ @as(f64, 1.0), @as(f64, 2.0) });
```

### Calling an instance method

```zig
var obj: zwren.Handle = try vm.new(my_class, constructor, .{});
try vm.call(obj, some_method, .{@as(f64, 42.0)});
```

### Binding foreign methods

Expose Zig functions to Wren:

```zig
fn vec2Alloc(c_vm: ?*c.WrenVM) callconv(.c) void {
    var wren = zwren.VirtualMachine.fromRaw(c_vm.?);
    wren.newForeign(.{ .x = @as(f32, 0), .y = @as(f32, 0) }) catch {};
}

fn vec2Add(c_vm: ?*c.WrenVM) callconv(.c) void {
    var wren = zwren.VirtualMachine.fromRaw(c_vm.?);
    const self = wren.getSlotForeign(Vec2, 0) catch return;
    const x = wren.getSlot(f64, 1) catch return;
    const y = wren.getSlot(f64, 2) catch return;
    wren.setSlot(self.x + @as(f32, @floatCast(x)), 0) catch {};
    _ = y;
}

try vm.bindForeignMethods("main", "Vec2", &.{
    .{ .sig = "",         .method = vec2Alloc, .flags = .{ .allocate = true } },
    .{ .sig = "add(_,_)", .method = vec2Add,   .flags = .{} },
});
```
