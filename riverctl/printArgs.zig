const std = @import("std");

pub fn print(args: []const [*:0]const u8) !void {
    const allocator = std.heap.page_allocator;

    // 创建一个 ArrayList 来存储二维字节数组
    var arrayList = std.ArrayList([]const u8).init(allocator);
    defer arrayList.deinit();

    // 向 ArrayList 添加元素
    for (args) |arg| {
        const new_arg: []const u8 = std.mem.span(arg);
        try arrayList.append(new_arg);
    }

    var filterList = std.ArrayList([]const u8).init(allocator);
    // 打印数组内容
    for (arrayList.items) |item| {
        // if (indexOf(item, "Super") != -1) {
        //     continue;
        // }
        try filterList.append(item);
    }
    const res: []u8 = try concatArrayList(allocator, filterList, " ");
    defer allocator.free(res);
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

pub fn concatArrayList(allocator: std.mem.Allocator, arr: std.ArrayList([]const u8), splitor: []const u8) ![]u8 {
    var result: []u8 = "";
    // 打印数组内容
    for (arr.items, 0..) |slice, i| {
        result = try concatStr(allocator, result, slice);
        if (i != arr.items.len - 1) {
            result = try concatStr(allocator, result, splitor);
        }
    }
    return result;
}

pub fn concatStr(allocator: std.mem.Allocator, st1: []const u8, st2: []const u8) ![]u8 {
    const len = st1.len + st2.len;
    var result = try allocator.alloc(u8, len);
    @memcpy(result[0..st1.len], st1);
    @memcpy(result[st1.len..], st2);

    return result;
}
