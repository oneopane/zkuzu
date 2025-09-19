const std = @import("std");

// Compile-time type utilities and safe casting helpers for zkuzu.
// This file intentionally has no dependency on query_result.zig to avoid cycles.

pub const TypeInfo = struct {
    /// Whether `T` is an `?Optional` type.
    ///
    /// Parameters:
    /// - `T`: Type to inspect (compile-time)
    ///
    /// Returns: `true` if `T` is optional; otherwise `false`
    pub fn isOptional(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Optional => true,
            else => false,
        };
    }

    /// Return the child type of an optional `T`, or `T` if not optional.
    ///
    /// Parameters:
    /// - `T`: Type to unwrap (compile-time)
    ///
    /// Returns: The inner type of `?T`, or `T` unchanged.
    pub fn childOfOptional(comptime T: type) type {
        const ti = @typeInfo(T);
        if (ti == .Optional) {
            return ti.Optional.child;
        }
        return T;
    }

    /// Whether `T` is a slice type (e.g. `[]u8`).
    ///
    /// Parameters:
    /// - `T`: Type to inspect
    ///
    /// Returns: `true` if `T` is a slice
    pub fn isSlice(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Pointer => |p| p.size == .Slice,
            else => false,
        };
    }

    /// Return the element type of a slice `T`.
    ///
    /// Errors: Compile error if `T` is not a slice.
    pub fn sliceChild(comptime T: type) type {
        const ti = @typeInfo(T);
        return switch (ti) {
            .Pointer => |p| if (p.size == .Slice) p.child else @compileError("sliceChild: expected slice type"),
            else => @compileError("sliceChild: expected slice type"),
        };
    }

    /// Whether `T` is a fixed-size array type `[N]Child`.
    pub fn isArray(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .Array => true,
            else => false,
        };
    }

    /// Return the element type of an array `T`.
    ///
    /// Errors: Compile error if `T` is not an array.
    pub fn arrayChild(comptime T: type) type {
        const ti = @typeInfo(T);
        return switch (ti) {
            .Array => |a| a.child,
            else => @compileError("arrayChild: expected array type"),
        };
    }

    /// Whether `T` is a byte slice (string-like) `[]u8`.
    pub fn isStringLike(comptime T: type) bool {
        if (!isSlice(T)) return false;
        const C = sliceChild(T);
        return C == u8;
    }

    /// Alias for `isStringLike`.
    pub fn isBytes(comptime T: type) bool {
        return isStringLike(T);
    }

    pub fn isBool(comptime T: type) bool {
        return T == bool;
    }
    pub fn isFloat(comptime T: type) bool {
        return T == f32 or T == f64;
    }
    pub fn isSignedInt(comptime T: type) bool {
        return T == i8 or T == i16 or T == i32 or T == i64;
    }
    pub fn isUnsignedInt(comptime T: type) bool {
        return T == u8 or T == u16 or T == u32 or T == u64;
    }

    /// Whether `T` is a supported scalar for conversions.
    ///
    /// Supported: bool, ints, uints, floats, `[]u8`
    pub fn isScalarSupported(comptime T: type) bool {
        return isBool(T) or isSignedInt(T) or isUnsignedInt(T) or isFloat(T) or isStringLike(T);
    }

    /// Return the type name of `T` at compile time.
    pub fn typeName(comptime T: type) []const u8 {
        return @typeName(T);
    }
};

pub const Cast = struct {
    pub const Error = error{ConversionError};

    /// Lossless cast to an integer type `T` with bounds checking.
    ///
    /// Parameters:
    /// - `T`: Destination integer type
    /// - `x`: Source value (any integer/float fits Zig rules)
    ///
    /// Returns: `x` cast to `T` or `Error.ConversionError` on overflow
    pub fn toInt(comptime T: type, x: anytype) Error!T {
        const TT = @TypeOf(x);
        comptime {
            if (!TypeInfo.isSignedInt(T) and !TypeInfo.isUnsignedInt(T))
                @compileError(std.fmt.comptimePrint("Cast.toInt: T must be integer, got {s}", .{@typeName(T)}));
        }
        return std.math.cast(T, x) orelse Error.ConversionError;
    }

    /// Lossy cast to a float type `T` (e.g., `f32` from `f64`).
    ///
    /// Parameters:
    /// - `T`: Destination float type
    /// - `x`: Source numeric value
    ///
    /// Returns: `x` converted to `T`
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
