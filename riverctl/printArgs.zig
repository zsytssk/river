const std = @import("std");

pub fn print(args: []const [*:0]const u8) !void {
    // _ = args;
    const allocator = std.heap.page_allocator;
    var res: []const u8 = "";
    defer allocator.free(res);
    for (args) |arg| {
        res = try std.fmt.allocPrint(allocator, "{s} {s}", .{ res, arg });
    }

    if (indexOf(res, "Alt") != -1 and indexOf(res, "Super") == -1) {
        std.log.info("riverctl {s}", .{res});
    }
}

fn indexOf(s: []const u8, sub: []const u8) i32 {
    for (s, 0..) |_, i| {
        if (std.mem.startsWith(u8, s[i..], sub)) {
            return @intCast(i);
        }
    }
    return -1;
}
