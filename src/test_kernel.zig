const std = @import("std");
const mem = std.mem;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const assert = std.debug.assert;

test "peer type resolution: error union and optional of same type" {
    const E = error{Foo};
    var a: E!*u8 = error.Foo;
    var b: ?*u8 = null;

    var t = true;
    const r1 = if (t) a else b;

    const T = @TypeOf(r1);

    try expectEqual(@as(T, error.Foo), r1);
}
