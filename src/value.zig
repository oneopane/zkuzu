const std = @import("std");

// Compile-time type utilities and safe casting helpers for zkuzu.
// This file intentionally has no dependency on query_result.zig to avoid cycles.

pub const TypeInfo = struct {
    pub fn isOptional(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Optional => true,
            else => false,
        };
    }

    pub fn childOfOptional(comptime T: type) type {
        const ti = @typeInfo(T);
        if (ti == .Optional) {
            return ti.Optional.child;
        }
        return T;
    }

    pub fn isSlice(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Pointer => |p| p.size == .Slice,
            else => false,
        };
    }

    pub fn sliceChild(comptime T: type) type {
        const ti = @typeInfo(T);
        return switch (ti) {
            .Pointer => |p| if (p.size == .Slice) p.child else @compileError("sliceChild: expected slice type"),
            else => @compileError("sliceChild: expected slice type"),
        };
    }

    pub fn isArray(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Array => true,
            else => false,
        };
    }

    pub fn arrayChild(comptime T: type) type {
        const ti = @typeInfo(T);
        return switch (ti) {
            .Array => |a| a.child,
            else => @compileError("arrayChild: expected array type"),
        };
    }

    pub fn isStringLike(comptime T: type) bool {
        if (!isSlice(T)) return false;
        const C = sliceChild(T);
        return C == u8;
    }

    pub fn isBytes(comptime T: type) bool {
        return isStringLike(T);
    }

    pub fn isBool(comptime T: type) bool { return T == bool; }
    pub fn isFloat(comptime T: type) bool { return T == f32 or T == f64; }
    pub fn isSignedInt(comptime T: type) bool { return T == i8 or T == i16 or T == i32 or T == i64; }
    pub fn isUnsignedInt(comptime T: type) bool { return T == u8 or T == u16 or T == u32 or T == u64; }

    pub fn isScalarSupported(comptime T: type) bool {
        return isBool(T) or isSignedInt(T) or isUnsignedInt(T) or isFloat(T) or isStringLike(T);
    }

    pub fn typeName(comptime T: type) []const u8 {
        return @typeName(T);
    }
};

pub const Cast = struct {
    pub const Error = error{ConversionError};

    pub fn toInt(comptime T: type, x: anytype) Error!T {
        const TT = @TypeOf(x);
        comptime {
            if (!TypeInfo.isSignedInt(T) and !TypeInfo.isUnsignedInt(T))
                @compileError(std.fmt.comptimePrint("Cast.toInt: T must be integer, got {s}", .{@typeName(T)}));
        }
        return std.math.cast(T, x) orelse Error.ConversionError;
    }

    pub fn toFloat(comptime T: type, x: anytype) Error!T {
        const TT = @TypeOf(x);
        _ = TT;
        comptime {
            if (!TypeInfo.isFloat(T))
                @compileError(std.fmt.comptimePrint("Cast.toFloat: T must be float, got {s}", .{@typeName(T)}));
        }
        return std.math.lossyCast(T, x);
    }
};

