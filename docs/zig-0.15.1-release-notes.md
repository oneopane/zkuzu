## [Language Changes](#toc-Language-Changes) [§](#Language-Changes){.hdr} {#Language-Changes}

Minor changes:

- packed union fields are no longer allowed to specify an align
  attribute, matching the existing behaviour with packed structs.
  Providing an override for the alignment previously did not affect the
  alignment of fields, and migration to these new rules takes the form
  of deleting the specifier. #22997

### [usingnamespace Removed](#toc-usingnamespace-Removed) [§](#usingnamespace-Removed){.hdr} {#usingnamespace-Removed}

This keyword added distance between the \"expected\" definition of a
declaration and its \"actual\" definition. Without it, discovering a
declaration\'s definition site is incredibly simple: find the definition
of the namespace you are looking in, then find the identifier being
defined within that type declaration. With `usingnamespace`, however,
the programmer can be led on a wild goose chase through different types
and files.

![Carmen the
Allocgator](https://ziglang.org/img/Carmen_1.svg){style="height: 12em; float: right"}

Not only does this harm readability for humans, but it is also
problematic for tooling; for instance, Autodoc cannot reasonably see
through non-trivial uses of `usingnamespace` (try looking for
dl_iterate_phdr under std.c in the 0.14.1 documentation).

By eliminating this feature, all identifiers can be trivially traced
back to where they are imported - by humans and machines alike.

Additionally, `usingnamespace` encourages poor namespacing. When
declarations are stored in a separate file, that typically means they
share something in common which is not shared with the contents of
another file. As such, it is likely a very reasonable choice to actually
expose the contents of that file via a separate namespace, rather than
including them in a more general parent namespace. To put it shortly:
**namespacing is good, actually**.

Finally, removal of this feature makes [Incremental
Compilation](#Incremental-Compilation) fundamentally simpler.

#### [Use Case: Conditional Inclusion](#toc-Use-Case-Conditional-Inclusion) [§](#Use-Case-Conditional-Inclusion){.hdr} {#Use-Case-Conditional-Inclusion}

`usingnamespace` can be used to conditionally include a declaration as
follows:

    pub usingnamespace if (have_foo) struct {
        pub const foo = 123;
    } else struct {};

The solution here is pretty simple: usually, you can just include the
declaration unconditionally. Zig\'s lazy compilation means that it will
not be analyzed unless referenced, so there are no problems!

    pub const foo = 123;

Occasionally, this is not a good solution, as it lacks safety. Perhaps
analyzing `foo` will always work, but will only give a meaningful result
if `have_foo` is true, and it would be a bug to use it in any other
case. In such cases, the declaration can be conditionally made a compile
error:

    pub const foo = if (have_foo)
        123
    else
        @compileError("foo not supported on this target");

This does break feature detection with [`@hasDecl`]{.tok-builtin}. If
feature detection is needed, a better approach---less prone to typos and
bitrotting---is to conditionally initialize the declaration to some
\"sentinel\" value which can be detected. A good choice is often the
[`void`]{.tok-type} value `{}`:

<figure>
<pre><code>const something = struct {
    // In this example, `foo` is supported but `bar` is not.
    const have_foo = true;
    const have_bar = false;
    pub const foo = if (have_foo) 123 else {};
    pub const bar = if (have_bar) undefined else {};
};

test &quot;use foo if supported&quot; {
    if (@TypeOf(something.foo) == void) return error.SkipZigTest; // unsupported
    try expect(something.foo == 123);
}

test &quot;use bar if supported&quot; {
    if (@TypeOf(something.bar) == void) return error.SkipZigTest; // unsupported
    try expect(something.bar == 456);
}

const expect = @import(&quot;std&quot;).testing.expect;</code></pre>
<figcaption>feature-detection.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test feature-detection.zig
1/2 feature-detection.test.use foo if supported...OK
2/2 feature-detection.test.use bar if supported...SKIP
1 passed; 1 skipped; 0 failed.</code></pre>
<figcaption>Shell</figcaption>
</figure>

#### [Use Case: Implementation Switching](#toc-Use-Case-Implementation-Switching) [§](#Use-Case-Implementation-Switching){.hdr} {#Use-Case-Implementation-Switching}

A close cousin of conditional inclusion, `usingnamespace` can also be
used to select from multiple implementations of a declaration at
comptime:

    pub usingnamespace switch (target) {
        .windows => struct {
            pub const target_name = "windows";
            pub fn init() T {
                // ...
            }
        },
        else => struct {
            pub const target_name = "something good";
            pub fn init() T {
                // ...
            }
        },
    };

The alternative to this is simpler and results in better code: make the
definition itself a conditional.

    pub const target_name = switch (target) {
        .windows => "windows",
        else => "something good",
    };
    pub const init = switch (target) {
        .windows => initWindows,
        else => initOther,
    };
    fn initWindows() T {
        // ...
    }
    fn initOther() T {
        // ...
    }

#### [Use Case: Mixins](#toc-Use-Case-Mixins) [§](#Use-Case-Mixins){.hdr} {#Use-Case-Mixins}

A very common use case for `usingnamespace` in the wild was to implement
mixins:

    /// Mixin to provide methods to manipulate the `count` field.
    pub fn CounterMixin(comptime T: type) type {
        return struct {
            pub fn incrementCounter(x: *T) void {
                x.count += 1;
            }
            pub fn resetCounter(x: *T) void {
                x.count = 0;
            }
        };
    }

    pub const Foo = struct {
        count: u32 = 0,
        pub usingnamespace CounterMixin(Foo);
    };

The alternative for this is based on the key observation made above:
**namespacing is good, actually**. The same logic can be applied to
mixins. The word \"counter\" in `incrementCounter` and `resetCounter`
already kind of *is* a namespace in spirit---it\'s like how we used to
have `std.ChildProcess` but have since renamed it to
`std.process.Child`. The same idea can be applied here: what if instead
of `foo.incrementCounter()`, you called `foo.counter.increment()`?

This can be achieved using a zero-bit field and `@fieldParentPtr`. Here
is the above example ported to use this mechanism:

    /// Mixin to provide methods to manipulate the `count` field.
    pub fn CounterMixin(comptime T: type) type {
        return struct {
            pub fn increment(m: *@This()) void {
                const x: *T = @alignCast(@fieldParentPtr("counter", m));
                x.count += 1;
            }
            pub fn reset(m: *@This()) void {
                const x: *T = @alignCast(@fieldParentPtr("counter", m));
                x.count = 0;
            }
        };
    }

    pub const Foo = struct {
        count: u32 = 0,
        counter: CounterMixin(Foo) = .{},
    };

This code works just like before, except the usage is
`foo.counter.increment()` rather than `foo.incrementCounter()`. We have
applied namespacing to our mixin using zero-bit fields. In fact, this
mechanism is *more* useful, because it allows you to also include
fields! For instance, in this case, we could move the `count` field to
`CounterMixin`. In this case that actually wouldn\'t be a mixin at all,
since that field is the only state `CounterMixin` uses---in fact, this
is a demonstration that the need for mixins is relatively rare. But in
cases where a mixin *is* appropriate, yet requires additional state,
this approach allows using the mixin without needing to duplicate fields
at each mixin site.

### [async and await keywords removed](#toc-async-and-await-keywords-removed) [§](#async-and-await-keywords-removed){.hdr}

Also removed `@frameSize`.

While [`suspend`]{.tok-kw}, [`resume`]{.tok-kw}, and other machinery
might remain depending on [Proposal: stackless coroutines as low-level
primitives](https://github.com/ziglang/zig/issues/23446), it is settled
that there will not be async/await keywords in the language. Instead,
they will be in the [Standard Library](#Standard-Library) as part of the
[Io Interface](#IO-as-an-Interface).

### [switch on non-exhaustive enums](#toc-switch-on-non-exhaustive-enums) [§](#switch-on-non-exhaustive-enums){.hdr}

Switching on non-exhaustive enums now allows mixing explicit tags with
the `_` prong (which represents all the unnamed values):

    switch (enum_val) {
        .special_case_1 => foo(),
        .special_case_2 => bar(),
        _, .special_case_3 => baz(),
    }

Additionally, it is now allowed to have both [`else`]{.tok-kw} and `_`:

    const Enum = enum(u32) {
        A = 1,
        B = 2,
        C = 44,
        _
    };

    fn someOtherFunction(value: Enum) void {
        // Does not compile giving "error: else and '_' prong in switch expression"
        switch (value) {
            .A   => {},
            .C   => {},
            else => {}, // Named tags go here (so, .B in this case)
            _    => {}, // Unnamed tags go here
        }
    }

### [Allow more operators on bool vectors](#toc-Allow-more-operators-on-bool-vectors) [§](#Allow-more-operators-on-bool-vectors){.hdr} {#Allow-more-operators-on-bool-vectors}

Allow binary not, binary and, binary or, binary xor, and boolean not
operators on vectors of [`bool`]{.tok-type}.

### [Inline Assembly: Typed Clobbers](#toc-Inline-Assembly-Typed-Clobbers) [§](#Inline-Assembly-Typed-Clobbers){.hdr} {#Inline-Assembly-Typed-Clobbers}

Until now these were stringly typed. It\'s kinda obvious when you think
about it.

    pub fn syscall1(number: usize, arg1: usize) usize {
        return asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (number),
              [arg1] "{rdi}" (arg1),
            : "rcx", "r11"
        );
    }

⬇️

    pub fn syscall1(number: usize, arg1: usize) usize {
        return asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (number),
              [arg1] "{rdi}" (arg1),
            : .{ .rcx = true, .r11 = true });
    }

To auto-upgrade, run `zig fmt`.

### [Allow \@ptrCast Single-Item Pointer to Slice](#toc-Allow-ptrCast-Single-Item-Pointer-to-Slice) [§](#Allow-ptrCast-Single-Item-Pointer-to-Slice){.hdr} {#Allow-ptrCast-Single-Item-Pointer-to-Slice}

This is essentially an extension of the 0.14.0 change which allowed
[`@ptrCast`]{.tok-builtin} to change the length of a slice. It can now
also cast from a single-item pointer to any slice, returning a slice
which refers to the same number of bytes as the operand.

<figure>
<pre><code>const std = @import(&quot;std&quot;);

test &quot;value to byte slice with @ptrCast&quot; {
    const val: u32 = 1;
    const bytes: []const u8 = @ptrCast(&amp;val);
    switch (@import(&quot;builtin&quot;).target.cpu.arch.endian()) {
        .little =&gt; try std.testing.expect(std.mem.eql(u8, bytes, &quot;\x01\x00\x00\x00&quot;)),
        .big =&gt; try std.testing.expect(std.mem.eql(u8, bytes, &quot;\x00\x00\x00\x01&quot;)),
    }
}</code></pre>
<figcaption>ptrcast-single.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test ptrcast-single.zig
1/1 ptrcast-single.test.value to byte slice with @ptrCast...OK
All 1 tests passed.</code></pre>
<figcaption>Shell</figcaption>
</figure>

Note that in a future release, it is planned to move this functionality
from [`@ptrCast`]{.tok-builtin} to a new [`@memCast`]{.tok-builtin}
builtin, with the intention that the latter is a safer builtin which
helps avoid unintentional out-of-bounds memory access. For more
information, see [issue
#23935](https://github.com/ziglang/zig/issues/23935).

### [New Rules for Arithmetic on undefined](#toc-New-Rules-for-Arithmetic-on-undefined) [§](#New-Rules-for-Arithmetic-on-undefined){.hdr} {#New-Rules-for-Arithmetic-on-undefined}

Zig 0.15.x begins to standardise the rules around how
[`undefined`]{.tok-null} behaves in different contexts---in particular,
how it behaves as an operand to arithmetic operators. In summary, only
operators which can never trigger Illegal Behavior permit
[`undefined`]{.tok-null} as an operand. Any other operator will trigger
Illegal Behavior (or a compile error if evaluated at
[`comptime`]{.tok-kw}) if any operand is [`undefined`]{.tok-null}.

Generally, it is always best practice to avoid any operation on
[`undefined`]{.tok-null}. If you do that, this language change, and any
that follow, are unlikely to affect you. If you are affected by this
language change, you might see a compile error on code which previously
worked:

<figure>
<pre><code>const a: u32 = 0;
const b: u32 = undefined;

test &quot;arithmetic on undefined&quot; {
    // This addition now triggers a compile error
    _ = a + b;
    // The solution is to simply avoid this operation!
}</code></pre>
<figcaption>arith-on-undefined.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test arith-on-undefined.zig
src/download/0.15.1/release-notes/arith-on-undefined.zig:6:13: error: use of undefined value here causes illegal behavior
    _ = a + b;
            ^
</code></pre>
<figcaption>Shell</figcaption>
</figure>

### [Error on Lossy Coercion from Int to Float](#toc-Error-on-Lossy-Coercion-from-Int-to-Float) [§](#Error-on-Lossy-Coercion-from-Int-to-Float){.hdr} {#Error-on-Lossy-Coercion-from-Int-to-Float}

This compile error has always been intended, but has gone unimplemented
until now. The compiler will now emit a compile error if an integer
value is coerced to a float at [`comptime`]{.tok-kw} but the integer
value could not be precisely represented due to floating-point precision
limitations. If you encounter this, you will get a compile error like
this:

<figure>
<pre><code>test &quot;big float literal&quot; {
    const val: f32 = 123_456_789;
    _ = val;
}</code></pre>
<figcaption>lossy_int_to_float_coercion.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test lossy_int_to_float_coercion.zig
src/download/0.15.1/release-notes/lossy_int_to_float_coercion.zig:2:22: error: type &#39;f32&#39; cannot represent integer value &#39;123456789&#39;
    const val: f32 = 123_456_789;
                     ^~~~~~~~~~~
</code></pre>
<figcaption>Shell</figcaption>
</figure>

The solution is typically just to change an integer literal to a
floating-point literal, thereby opting in to floating-point rounding
behavior:

<figure>
<pre><code>test &quot;big float literal&quot; {
    const val: f32 = 123_456_789.0;
    _ = val;
}</code></pre>
<figcaption>lossy_int_to_float_coercion_new.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test lossy_int_to_float_coercion_new.zig
1/1 lossy_int_to_float_coercion_new.test.big float literal...OK
All 1 tests passed.</code></pre>
<figcaption>Shell</figcaption>
</figure>

## [Standard Library](#toc-Standard-Library) [§](#Standard-Library){.hdr} {#Standard-Library}

Uncategorized changes:

- `fs.Dir.copyFile` no longer can fail with `error.OutOfMemory`
- `fs.Dir.atomicFile` now requires a `write_buffer` in the options
- `fs.AtomicFile` now has a `File.Writer` field rather than `File` field
- `fs.File`: removed `WriteFileOptions`, `writeFileAll`,
  `writeFileAllUnseekable` in favor of `File.Writer`
- `posix.sendfile` removed in favor of `fs.File.Reader.sendFile`

### [Writergate](#toc-Writergate) [§](#Writergate){.hdr} {#Writergate}

[Previous Scandal](/download/0.9.0/release-notes.html#Allocgate)

All existing std.io readers and writers are deprecated in favor of the
newly provided `std.Io.Reader` and `std.Io.Writer` which are
*non-generic* and have the buffer above the vtable - in other words the
buffer is **in the interface, not the implementation**. This means that
although Reader and Writer are no longer generic, they are still
transparent to optimization; all of the interface functions have a
concrete hot path operating on the buffer, and only make vtable calls
when the buffer is full.

These changes are extremely breaking. I am sorry for that, but I have
carefully examined the situation and acquired confidence that this is
the direction that Zig needs to go. I hope you will strap in your
seatbelt and come along for the ride; it will be worth it.

#### [Motivation](#toc-Motivation) [§](#Motivation){.hdr} {#Motivation}

[Systems Distributed 2025 Talk: Don\'t Forget To
Flush](https://www.youtube.com/watch?v=f30PceqQWko)

- The old interface was generic, poisoning structs that contain them and
  forcing all functions to be generic as well with `anytype`. The new
  interface is concrete.
  - Bonus: the concreteness removes temptation to make APIs operate
    directly on networking streams, file handles, or memory buffers,
    giving us a more reusable body of code. For example, `http.Server`
    after the change no longer depends on `std.net` - it operates only
    on streams now.
- The old interface passed errors through rather than defining its own
  set of error codes. This made errors in streams about as useful as
  `anyerror`. The new interface carefully defines precise error sets for
  each function with actionable meaning.
- The new interface has the buffer in the interface, rather than as a
  separate \"BufferedReader\" / \"BufferedWriter\" abstraction. This is
  more optimizer friendly, particularly for debug mode.
- The new interface supports high level concepts such as vectors,
  splatting, and direct file-to-file transfer, which can propagate
  through an entire graph of readers and writers, reducing syscall
  overhead, memory bandwidth, and CPU usage.
- The new interface has \"peek\" functionality - a buffer awareness that
  offers API convenience for the user as well as simplicity for the
  implementation.

#### [Adapter API](#toc-Adapter-API) [§](#Adapter-API){.hdr} {#Adapter-API}

If you have an old stream and you need a new one, you can use
`adaptToNewApi()` like this:

    fn foo(old_writer: anytype) !void {
        var adapter = old_writer.adaptToNewApi(&.{});
        const w: *std.Io.Writer = &adapter.new_interface;
        try w.print("{s}", .{"example"});
        // ...
    }

#### [New std.Io.Writer and std.Io.Reader API](#toc-New-stdIoWriter-and-stdIoReader-API) [§](#New-stdIoWriter-and-stdIoReader-API){.hdr} {#New-stdIoWriter-and-stdIoReader-API}

These **ring buffers** have a bunch of handy new APIs that are more
convenient, perform better, and are not generic. For instance look at
how reading until a delimiter works now:

    while (reader.takeDelimiterExclusive('\n')) |line| {
        // do something with line...
    } else |err| switch (err) {
        error.EndOfStream, // stream ended not on a line break
        error.StreamTooLong, // line could not fit in buffer
        error.ReadFailed, // caller can check reader implementation for diagnostics
        => |e| return e,
    }

These streams also feature some unique concepts compared with other
languages\' stream implementations:

- The concept of **discarding** when reading: allows efficiently
  ignoring data. For instance a decompression stream, when asked to
  discard a large amount of data, can skip decompression of entire
  frames.
- The concept of **splatting** when writing: this allows a logical
  \"memset\" operation to pass through I/O pipelines without actually
  doing any memory copying, turning an O(M\*N) operation into O(M)
  operation, where M is the number of streams in the pipeline and N is
  the number of repeated bytes. In some cases it can be even more
  efficient, such as when splatting a zero value that ends up being
  written to a file; this can be lowered as a seek forward.
- Sending a file when writing: this allows an I/O pipeline to do direct
  fd-to-fd copying when the operating system supports it.
- The stream user provides the buffer, but the stream implementation
  decides the minimum buffer size. This effectively moves state from the
  stream implementation into the user\'s buffer

#### [std.fs.File.Reader and std.fs.File.Writer](#toc-stdfsFileReader-and-stdfsFileWriter) [§](#stdfsFileReader-and-stdfsFileWriter){.hdr} {#stdfsFileReader-and-stdfsFileWriter}

`std.fs.File.Reader` memoizes key information about a file handle such
as:

- The size from calling stat, or the error that occurred therein.
- The current seek position.
- The error that occurred when trying to seek.
- Whether reading should be done positionally or streaming.
- Whether reading should be done via fd-to-fd syscalls (e.g.
  `sendfile`)\
  versus plain variants (e.g. `read`).

Fulfills the `std.Io.Reader` interface.

This API turned out to be super handy in practice. Having a concrete
type to pass around that memoizes file size is really nice. Most code
that previously was calling seek functions on a file handle should be
updated to operate on this API instead, causing those seeks to become
no-ops thanks to positional reads, while still supporting a fallback to
streaming reading.

`std.fs.File.Writer` is the same idea but for writing.

#### [Upgrading std.io.getStdOut().writer().print()](#toc-Upgrading-stdiogetStdOutwriterprint) [§](#Upgrading-stdiogetStdOutwriterprint){.hdr} {#Upgrading-stdiogetStdOutwriterprint}

Please use buffering! And **don\'t forget to flush**!

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // ...

    try stdout.print("...", .{});

    // ...

    try stdout.flush();

#### [reworked std.compress.flate](#toc-reworked-stdcompressflate) [§](#reworked-stdcompressflate){.hdr} {#reworked-stdcompressflate}

![Carmen the
Allocgator](https://ziglang.org/img/Carmen_4.svg){style="height: 16em; float: right"}

`std.compress` API restructured everything to do with flate, which
includes zlib and gzip. `std.compress.flate.Decompress` is your main API
now and it has a container parameter.

New API example:

    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &decompress_buffer);
    const decompress_reader: *std.Io.Reader = &decompress.reader;

If `decompress_reader` will be piped entirely to a particular `*Writer`,
then give it an empty buffer:

    var decompress: std.compress.flate.Decompress = .init(reader, .zlib, &.{});
    const n = try decompress.streamRemaining(writer);

Compression functionality was removed. Sorry, you will have to copy the
old code into your application, or use a third party package.

It will be nice to get deflate back into the Zig standard library, but
for now, progressing the language takes priority over progressing the
standard library, and this change is on the path towards locking in the
final language design with respect to [I/O as an
Interface](#IO-as-an-Interface).

Some notable factors:

- New implementation does not calculate a checksum since it can be done
  out-of-band.
- New implementation has the fancy match logic replaced with a naive
  [`for`]{.tok-kw} loop. In the future it would be nice to add a memory
  copying utility for this that zstd would also use. Despite this, the
  new implementation performs roughly 10% better in an untar
  implementation, while reducing compiler code size by 2%. #24614

#### [CountingWriter Deleted](#toc-CountingWriter-Deleted) [§](#CountingWriter-Deleted){.hdr} {#CountingWriter-Deleted}

- If you were discarding the bytes, use `std.Io.Writer.Discarding`,
  which has a count.
- If you were allocating the bytes, use `std.Io.Writer.Allocating`,
  since you can check how much was allocated.
- If you were writing to a fixed buffer, use `std.Io.Writer.fixed`, and
  then check the `end` position.
- Otherwise, try not to create an entire node in the stream graph solely
  for counting bytes. It\'s very disruptive to optimal buffering.

#### [BufferedWriter Deleted](#toc-BufferedWriter-Deleted) [§](#BufferedWriter-Deleted){.hdr} {#BufferedWriter-Deleted}

    const stdout_file = std.fs.File.stdout().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // Don't forget to flush!

⬇️

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!

Consider making your stdout buffer global.

### [\"{f}\" Required to Call format Methods](#toc-f-Required-to-Call-format-Methods) [§](#f-Required-to-Call-format-Methods){.hdr} {#f-Required-to-Call-format-Methods}

Turn on `-freference-trace` to help you find all the format string
breakage.

Example:

    std.debug.print("{}", .{std.zig.fmtId("example")});

This will now cause a compile error:

    error: ambiguous format string; specify {f} to call format method, or {any} to skip it

Fixed by:

    std.debug.print("{f}", .{std.zig.fmtId("example")});

Motivation: eliminate these two footguns:

Introducing a `format` method to a struct caused a bug if there was
formatting code somewhere that prints with {} and then starts rendering
differently.

Removing a `format` method to a struct caused a bug if there was
formatting code somewhere that prints with {} and is now changed without
notice.

Now, introducing a `format` method will cause compile errors at all `{}`
sites. In the future, it will have no effect.

Similarly, eliminating a `format` method will not change any sites that
use `{}`.

Using `{f}` always tries to call a `format` method, causing a compile
error if none exists.

### [Format Methods No Longer Have Format Strings or Options](#toc-Format-Methods-No-Longer-Have-Format-Strings-or-Options) [§](#Format-Methods-No-Longer-Have-Format-Strings-or-Options){.hdr} {#Format-Methods-No-Longer-Have-Format-Strings-or-Options}

    pub fn format(
        this: @This(),
        comptime format_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void { ... }

⬇️

    pub fn format(this: @This(), writer: *std.io.Writer) std.io.Writer.Error!void { ... }

The deleted `FormatOptions` are now for numbers only.

Any state that you got from the format string, there are three suggested
alternatives:

1.  different format methods

<!-- -->

    pub fn formatB(foo: Foo, writer: *std.io.Writer) std.io.Writer.Error!void { ... }

This can be called with
[`"{f}"`]{.tok-str}`, .{std.fmt.alt(Foo, .formatB)}`.

2.  `std.fmt.Alt`

<!-- -->

    pub fn bar(foo: Foo, context: i32) std.fmt.Alt(F, F.baz) {
        return .{ .data = .{ .context = context } };
    }
    const F = struct {
        context: i32,
        pub fn baz(f: F, writer: *std.io.Writer) std.io.Writer.Error!void { ... }
    };

This can be called with
[`"{f}"`]{.tok-str}`, .{foo.bar(`[`1234`]{.tok-number}`)}`.

3.  return a struct instance that has a format method, combined with
    `{f}`.

<!-- -->

    pub fn bar(foo: Foo, context: i32) F {
        return .{ .context = 1234 };
    }
    const F = struct {
        context: i32,
        pub fn format(f: F, writer: *std.io.Writer) std.io.Writer.Error!void { ... }
    };

This can be called with
[`"{f}"`]{.tok-str}`, .{foo.bar(`[`1234`]{.tok-number}`)}`.

### [Formatted Printing No Longer Deals with Unicode](#toc-Formatted-Printing-No-Longer-Deals-with-Unicode) [§](#Formatted-Printing-No-Longer-Deals-with-Unicode){.hdr} {#Formatted-Printing-No-Longer-Deals-with-Unicode}

If you were relying on alignment combined with Unicode codepoints, it is
now ASCII/bytes only. The previous implementation was not fully
Unicode-aware. If you want to align Unicode strings you need full
Unicode support which the standard library does not provide.

### [New Formatted Printing Specifiers](#toc-New-Formatted-Printing-Specifiers) [§](#New-Formatted-Printing-Specifiers){.hdr} {#New-Formatted-Printing-Specifiers}

- {t} is shorthand for `@tagName()` and `@errorName()`
- {d} and other integer printing can be used with custom types which
  calls `formatNumber` method.
- {b64}: output string as standard base64

### [De-Genericify Linked Lists](#toc-De-Genericify-Linked-Lists) [§](#De-Genericify-Linked-Lists){.hdr} {#De-Genericify-Linked-Lists}

With these changes, there\'s no longer any incentive to hand-roll
next/prev pointers. A little bit less bloat too.

Migration guide:

    std.DoublyLinkedList(T).Node

⬇️

    struct {
        node: std.DoublyLinkedList.Node,
        data: T,
    }

Then use [`@fieldParentPtr`]{.tok-builtin} to get from `node` to `data`.

In many cases there\'s a better pattern instead which is to put the node
intrusively into the data structure. If you\'re not already doing that,
there\'s a good chance linked list is the wrong data structure.

### [std.Progress supports progress bar escape codes](#toc-stdProgress-supports-progress-bar-escape-codes) [§](#stdProgress-supports-progress-bar-escape-codes){.hdr} {#stdProgress-supports-progress-bar-escape-codes}

Turns out there are [escape codes for sending progress status to the
terminal](https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC).

It integrates with `--watch` in the [Build System](#Build-System) to set
error state when failures occur, and clear it when they are fixed, also
to clear progress when waiting for user input.

`std.Progress` gains a `setStatus` function and the following enum:

    pub const Status = enum {
        /// Indicates the application is progressing towards completion of a task.
        /// Unless the application is interactive, this is the only status the
        /// program will ever have!
        working,
        /// The application has completed an operation, and is now waiting for user
        /// input rather than calling exit(0).
        success,
        /// The application encountered an error, and is now waiting for user input
        /// rather than calling exit(1).
        failure,
        /// The application encountered at least one error, but is still working on
        /// more tasks.
        failure_working,
    };

### [HTTP Client and Server](#toc-HTTP-Client-and-Server) [§](#HTTP-Client-and-Server){.hdr} {#HTTP-Client-and-Server}

These APIs and implementations have been completely reworked.

Server API no longer depends on `std.net`. Instead, it only depends on
`std.Io.Reader` and `std.Io.Writer`. It also has all the arbitrary
limitations removed. For instance, there is no longer a limit on how
many headers can be sent.

    var read_buffer: [8000]u8 = undefined;
    var server = std.http.Server.init(connection, &read_buffer);

⬇️

    var recv_buffer: [4000]u8 = undefined;
    var send_buffer: [4000]u8 = undefined;
    var conn_reader = connection.stream.reader(&recv_buffer);
    var conn_writer = connection.stream.writer(&send_buffer);
    var server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

Server and Client both share `std.http.Reader` and `std.http.BodyWriter`
which again only depends on I/O streams and not networking.

Client upgrade example:

    var server_header_buffer: [1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    const body_reader = try req.reader();
    // read from body_reader...

    var it = req.response.iterateHeaders();
    while (it.next()) |header| {
        _ = header.name;
        _ = header.value;
    }

⬇️

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});

    // Once we call reader() below, strings inside `response.head` are invalidated.
    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        _ = header.name;
        _ = header.value;
    }

    // Optimal size depends on how you will use the reader.
    var reader_buffer: [100]u8 = undefined;
    const body_reader = try response.reader(&reader_buffer);

### [TLS Client](#toc-TLS-Client) [§](#TLS-Client){.hdr} {#TLS-Client}

`std.crypto.tls.Client` no longer depends on `std.net` or `std.fs`.
Instead, it only depends on `std.Io.Reader` and `std.Io.Writer`.

### [ArrayList: make unmanaged the default](#toc-ArrayList-make-unmanaged-the-default) [§](#ArrayList-make-unmanaged-the-default){.hdr} {#ArrayList-make-unmanaged-the-default}

- `std.ArrayList` -\> `std.array_list.Managed`
- `std.ArrayListAligned` -\> `std.array_list.AlignedManaged`

Warning: these will both eventually be removed entirely.

Having an extra field is more complicated than not having an extra
field, so not having it is the null hypothesis. What pattern does having
an allocator field allow that not having one doesn\'t?

- avoiding accidentally using the wrong allocator
- convenience when you need to pass an allocator also

But there are downsides:

- worse method function signatures in the face of reservations
- inability to statically initialize
- extra memory storage cost, particularly for nested containers

The reasoning goes like this: the upsides are not worth the downsides.
Also, given that the correct allocator is always handy, and incorrect
use can be trivially safety-checked, the simplicity of only having one
implementation is quite valuable compared to the convenience that is
gained by having a second implementation.

In practice, this has not been a controversial change with experienced
Zig users.

### [Ring Buffers](#toc-Ring-Buffers) [§](#Ring-Buffers){.hdr} {#Ring-Buffers}

[There are too many ring buffer implementations in the standard
library!](https://github.com/ziglang/zig/issues/19231)

`std.fifo.LinearFifo` is removed due to being poorly designed. This data
structure was unnecessarily generic due to accepting a comptime enum
parameter that determined whether its buffer was heap-allocated with an
Allocator parameter, passed in as an externally-owned slice, or stored
in the struct itself. Each of these different buffer management
strategies describes a fundamentally different data structure.

Furthermore, most of its real-world use cases are subsumed by [New
std.Io.Writer and std.Io.Reader
API](#New-stdIoWriter-and-stdIoReader-API) which are both ring buffers.

Similarly, `std.RingBuffer` is removed since it was only used by the
zstd implementation which has been upgraded to use [New std.Io.Writer
and std.Io.Reader API](#New-stdIoWriter-and-stdIoReader-API).

There was also `std.compress.flate.CircularBuffer` which was internal to
the flate implementation; now deleted.

There was also one each in [HTTP Client and
Server](#HTTP-Client-and-Server) - again deleted in favor of [New
std.Io.Writer and std.Io.Reader
API](#New-stdIoWriter-and-stdIoReader-API).

Even with all five of these deletions, these things pop up like
whack-a-mole. Here are some more ring buffers that have been spotted:

- `lib/std/compress/lzma/decode/lzbuffer.zig` - internal to lzma
  implementation.
- `lib/std/crypto/tls.zig` - made redundant with std.Io.Reader.
- `lib/std/debug/FixedBufferReader.zig` - made redundant by
  std.Io.Reader\'s excellent Debug mode performance.
- [this random pull
  request](https://github.com/ziglang/zig/pull/24705) - nice try, you
  almost got away with it!!

Jokes aside, there will likely be room for a general-purpose, reusable
ring buffer implementation in the standard library, however, first ask
yourself if what you really need is `std.Io.Reader` or `std.Io.Writer`.

### [Removal of BoundedArray](#toc-Removal-of-BoundedArray) [§](#Removal-of-BoundedArray){.hdr} {#Removal-of-BoundedArray}

This data structure was popular due to being trivially copyable.
However, such convenience comes at a cost.

To upgrade, categorize code based on where the limit comes from:

- Is it an arbitrary limit for which the BoundedArray usage is making a
  reasonable guess at the upper bound, or deciding resource limits?
  Don\'t guess. Don\'t make that choice for the calling code. Accept a
  buffer as a slice as an input, or use dynamic allocation. (example:
  the markdown code in #24699)
- Is it type safety around a stack buffer? Just use ArrayListUnmanaged.
  It\'s fine. It\'s actually really convenient that this same data
  structure works here. (example: test_switch_dispatch_loop.zig in
  #24699)

`std.ArrayList` now has \"Bounded\" variants of all the
\"AssumeCapacity\" methods:

    var stack = try std.BoundedArray(i32, 8).fromSlice(initial_stack);

⬇️

    var buffer: [8]i32 = undefined;
    var stack = std.ArrayListUnmanaged(i32).initBuffer(&buffer);
    try stack.appendSliceBounded(initial_stack);

- Is it an ordered set with a well-defined maximum capacity? Quite rare.
  Just free-code it. (example: changes to Zcu.zig in #24699)
- Is it being used as a growable array that can be copied? This wastes
  time copying undefined memory all over the place and causes
  unnecessary generic code bloat.

### [Deletions and Deprecations](#toc-Deletions-and-Deprecations) [§](#Deletions-and-Deprecations){.hdr} {#Deletions-and-Deprecations}

- std.fs.File.reader -\> std.fs.File.deprecatedReader
- std.fs.File.writer -\> std.fs.File.deprecatedWriter
- std.fmt.fmtSliceEscapeLower -\> std.ascii.hexEscape
- std.fmt.fmtSliceEscapeUpper -\> std.ascii.hexEscape
- std.zig.fmtEscapes -\> std.zig.fmtString
- std.fmt.fmtSliceHexLower -\> {x}
- std.fmt.fmtSliceHexUpper -\> {X}
- std.fmt.fmtIntSizeDec -\> {B}
- std.fmt.fmtIntSizeBin -\> {Bi}
- std.fmt.fmtDuration -\> {D}
- std.fmt.fmtDurationSigned -\> {D}
- std.fmt.Formatter -\> std.fmt.Alt
  - now takes context type explicitly
  - no fmt string
- std.fmt.format -\> std.Io.Writer.print
- std.io.GenericReader -\> std.Io.Reader
- std.io.GenericWriter -\> std.Io.Writer
- std.io.AnyReader -\> std.Io.Reader
- std.io.AnyWriter -\> std.Io.Writer
- deleted `std.io.SeekableStream`
  - Instead, use `*std.fs.File.Reader`, `*std.fs.File.Writer`, or
    `std.ArrayListUnmanaged` concrete types, because the implementations
    will be fundamentally different based on whether you are operating
    on files or memory.
- deleted `std.io.BitReader`
  - Bit reading should not be abstracted at this layer; it just makes
    your hot loop harder to optimize. Tightly couple this code with your
    stream implementation.
- deleted `std.io.BitWriter`
  - ditto
- deleted `std.Io.LimitedReader`
- deleted `std.Io.BufferedReader`
- deleted `std.fifo`

## [Build System](#toc-Build-System) [§](#Build-System){.hdr} {#Build-System}

Uncategorized changes:

- `zig build`: print newline before build summary

### [Removed Deprecated Implicit Root Module](#toc-Removed-Deprecated-Implicit-Root-Module) [§](#Removed-Deprecated-Implicit-Root-Module){.hdr} {#Removed-Deprecated-Implicit-Root-Module}

Zig 0.14.0 introduced the `root_module` field to
`std.Build.ExecutableOptions` and friends, deprecating the old fields
which defined the root module like `root_source_file`. Zig 0.15.x
removes the deprecated fields. If you did not migrate in the previous
release cycle, you will encounter compile errors such as this one:

<figure>
<pre><code>pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = &quot;foo&quot;,
        .root_source_file = b.path(&quot;src/main.zig&quot;),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    b.installArtifact(exe);
}

test {
    _ = &amp;build;
}
const std = @import(&quot;std&quot;);</code></pre>
<figcaption>deprecated-addExecutable.zig</figcaption>
</figure>

<figure>
<pre><code>$ zig test deprecated-addExecutable.zig
src/download/0.15.1/release-notes/deprecated-addExecutable.zig:4:10: error: no field named &#39;root_source_file&#39; in struct &#39;Build.ExecutableOptions&#39;
        .root_source_file = b.path(&quot;src/main.zig&quot;),
         ^~~~~~~~~~~~~~~~
/home/ci/deps/zig-x86_64-linux-0.15.1/lib/std/Build.zig:771:31: note: struct declared here
pub const ExecutableOptions = struct {
                              ^~~~~~
referenced by:
    test_0: src/download/0.15.1/release-notes/deprecated-addExecutable.zig:12:10
</code></pre>
<figcaption>Shell</figcaption>
</figure>

For this change\'s migration path, please see [the corresponding section
of the Zig 0.14.0 release
notes](https://ziglang.org/download/0.14.0/release-notes.html#Creating-Artifacts-from-Existing-Modules).

### [macOS File System Watching](#toc-macOS-File-System-Watching) [§](#macOS-File-System-Watching){.hdr} {#macOS-File-System-Watching}

The `--watch` flag to `zig build` is now supported on macOS. In Zig
0.14.0, the flag was accepted, but unfortunately behaved incorrectly
with most editors. In Zig 0.15.x, this functionality has been [rewritten
on macOS](https://github.com/ziglang/zig/pull/24649) to use the File
System Events API for fast and reliable file system update watching.

So, if you were avoiding `--watch` in previous Zig versions due to the
macOS bug, you can now use it safely. This is particularly useful if you
are interested in trying [Incremental
Compilation](#Incremental-Compilation), since the typical way to use
that feature today involves passing the flags `--watch -fincremental` to
`zig build`.

### [Web Interface and Time Report](#toc-Web-Interface-and-Time-Report) [§](#Web-Interface-and-Time-Report){.hdr} {#Web-Interface-and-Time-Report}

Zig 0.14.0 included an experimental web interface for the
work-in-progress built-in fuzzer. In this version, that interface has
been replaced with a more general web interface for the build system in
general. This interface can be exposed using `zig build --webui`. When
this option is passed, the `zig build` process will continue running
even after the build completes.

The web interface is, by itself, relatively uninteresting: it merely
shows the list of build steps and information about which are in
progress, and has a button to manually trigger a rebuild (hence giving a
possible alternative to the `zig build --watch` workflow). If `--fuzz`
is passed to `zig build`, it also exposes the [Fuzzer](#Fuzzer)
interface, which is mostly unchanged from 0.14.0.

However, the web interface also exposes a new feature known as \"time
reports\". By passing the new `--time-report` option to `zig build`, the
web interface will include expandable information about the time taken
to evaluate every step in the graph. In particular, any
`std.Build.Step.Compile` in the graph will be associated with detailed
information about which parts of the Zig compiler pipeline were fast and
slow, and which individual files and declarations took the most time to
semantically analyze, generate machine code for, and link into the
binary.

![zig build web
interface](release-notes/build-webui.png){style="width:100%"}

This is a relatively advanced feature, but it can be very useful for
determining parts of your code which are needlessly slowing down
compilation, by opening the \"Declarations\" table and viewing the first
few rows.

![compile step time
report](release-notes/build-webui-time-report.png){style="width:100%"}

LLVM pass timing information is also provided if the LLVM backend was
used for the compilation.

## [Compiler](#toc-Compiler) [§](#Compiler){.hdr} {#Compiler}

### [x86 Backend](#toc-x86-Backend) [§](#x86-Backend){.hdr} {#x86-Backend}

![Carmen the
Allocgator](https://ziglang.org/img/Carmen_10.svg){style="height: 16em; float: right"}

**Zig 0.15.x enables Zig\'s self-hosted x86_64 code generation backend
by default in Debug mode.**

More specifically, this backend is now the default when targeting x86_64
in Debug mode, except on NetBSD, OpenBSD, and Windows, where the LLVM
backend is still the default due to [Linker](#Linker) deficiencies.

When this backend is selected, you will begin to reap the benefits of
the investments the Zig project has made over the past few years.
Compilation time is *significantly* improved---around a 5x decrease
compared to LLVM in most cases. **This is only the beginning;** the
self-hosted x86_64 backend has been built to support [Incremental
Compilation](#Incremental-Compilation), which will result in another
extreme speed-up when it is stable enough to be enabled by default. Fast
compilation is a key goal of the Zig project, and one we have been
quietly making progress on for years---this release sees those efforts
starting to come to fruition.

Using the self-hosted x86 backend also means you are not subject to the
effects of upstream LLVM bugs, of which [we are currently tracking over
60](https://github.com/ziglang/zig/issues?q=is%3Aissue%20state%3Aopen%20label%3Abackend-llvm%20label%3Aupstream).
In fact, the self-hosted x86 backend already passes a larger subset of
our \"behavior test suite\" than the LLVM backend does (1984/2008 vs
1977/2008). In other words, this backend provides a more complete and
correct implementation of the Zig language.

Of course, the self-hosted x86 backend does currently have [some
deficiencies and bugs of its
own](https://github.com/ziglang/zig/issues?q=is%3Aissue%20state%3Aopen%20label%3Abackend-self-hosted%20label%3Aarch-x86_64).
If you are affected by any of these issues, you can use LLVM backend for
Debug builds by passing `-fllvm` on the command-line or by setting
`.use_llvm = `[`true`]{.tok-null} when creating a
`std.Build.Step.Compile`. The self-hosted x86 backend is also currently
known to emit [slower machine code than the LLVM
backend](https://github.com/ziglang/zig/issues/24144).

But in most cases, the self-hosted backend is now a better choice for
development. For instance, the Zig core team have been building the Zig
compiler almost exclusively with the self-hosted x86 backend instead of
LLVM for quite a while. This has been a serious improvement to our
workflows, with the Zig compiler building in just a few seconds rather
than 1-2 minutes. You can now expect to see similar improvements to your
own development experience.

### [aarch64 Backend](#toc-aarch64-Backend) [§](#aarch64-Backend){.hdr} {#aarch64-Backend}

Having improved the self-hosted [x86 Backend](#x86-Backend) enough for
it to be enabled by default, Jacob has set his eyes on a new target:
aarch64. This architecture is growing in popularity, particularly since
modern Apple hardware is based on it. Therefore, aarch64 is the Zig
project\'s next big focus for self-hosted code generation without LLVM.

For this work-in-progress backend, Jacob has been able to take the
lessons learnt from the x86 backend to explore new design directions.
It\'s too early to be sure, but we expect that the new design will
improve both compiler performance (being even faster than the
self-hosted x86_64 backend) *and* the quality of emitted machine code,
with the ultimate goal of becoming competitive with LLVM\'s codegen
quality in Debug mode. [This devlog](/devlog/2025/#2025-07-23) has some
more details.

This backend is passing 1656/1972 (84%) behavior tests relative to LLVM,
so is not ready to be enabled by default, nor is it currently usable in
any real use case. However, it is making rapid progress, and is expected
to become the default for Debug mode in a future release.

Our work on self-hosted code generation backends is a part of our
long-term plan to [transition LLVM to an optional
dependency](https://kristoff.it/blog/zig-new-relationship-llvm/) and
[decouple it from the compiler
implementation](https://github.com/ziglang/zig/issues/16270). Achieving
this goal will lead to large decreases in compile time, good support for
incremental compilation in Debug builds, and could even allow us to
explore language features which LLVM cannot lower effectively.

### [Incremental Compilation](#toc-Incremental-Compilation) [§](#Incremental-Compilation){.hdr} {#Incremental-Compilation}

Zig 0.15.x makes further progress on the work-in-progress Incremental
Compilation functionality, which allows the compiler to perform very
fast rebuilds by only re-compiling code which has changed. Various bugs
have been fixed, particularly relating to changing file imports.

This feature is still experimental---it has known bugs and can lead to
miscompilations or incorrect compile errors. However, it is now stable
enough to be used reliably in combination with `-fno-emit-bin`. **If you
have a large project that does not compile instantly, you should be
taking advantage of `--watch` combined with `-fincremental` and
`-Dno-bin` for compile errors.** Seriously, it\'s really good. Please
chat with someone if you have trouble figuring out how to expose
`-Dno-bin` from your build script.

The next release cycle will continue to make progress towards enabling
Incremental Compilation by default. In the meantime, if you are
interested in trying this experimental feature, take a look at
[#21165](https://github.com/ziglang/zig/issues/21165).

### [Threaded Codegen](#toc-Threaded-Codegen) [§](#Threaded-Codegen){.hdr} {#Threaded-Codegen}

The Zig compiler is designed to be parallelized, so that different
pieces of compilation work can run in parallel with one another to
improve compiler performance. In the past the Zig compiler was largely
single-threaded, but 0.14.0 introduced the ability for certain compiler
backends to run in parallel with the frontend (Semantic Analysis). Zig
0.15.x continues down this path by allowing Semantic Analysis, Code
Generation, and Linking to *all* happen in parallel with one another.
Code Generation in particular can itself be split across arbitrarily
many threads.

Compared to 0.14.0, this typically leads to another performance boost
when using self-hosted backends such as the [x86 Backend](#x86-Backend).
The improvement in wall-clock time varies from relatively insignificant
to upwards of 50% depending on the specific code being compiled.
However, as one real-world data point, building the Zig compiler using
its own x86_64 backend got 27% faster on one system from this change,
with the wall-clock time going from 13.8s to 10.0s.

[This devlog](https://ziglang.org/devlog/2025/#2025-06-14) looks a
little more closely at this change, but in short, you can expect better
compiler performance when using self-hosted backends thanks to this
parallelization. [Oh, and you get more detailed progress information
too.](https://asciinema.org/a/bgDEbDt4AkZWORDX1YBMuKBD3)

### [Allow configuring UBSan mode at the module level](#toc-Allow-configuring-UBSan-mode-at-the-module-level) [§](#Allow-configuring-UBSan-mode-at-the-module-level){.hdr} {#Allow-configuring-UBSan-mode-at-the-module-level}

The Zig CLI and build system now allow more control over the UBSan mode.
`zig build-exe` and friends accept `-fsanitize-c=trap` and
`-fsanitize-c=full`, with the old `-fsanitize-c` spelling being
equivalent to the latter.

- With `full`, the UBSan runtime is built and linked into the program,
  resulting in better error messages when undefined behavior is
  triggered, at the cost of code size.
- With `trap`, trap instructions are inserted instead, resulting in
  `SIGILL` when undefined behavior is triggered, but smaller code size.

If no flag is given, the default depends on the build mode.

For [zig cc](#zig-cc), in addition to the existing
`-fsanitize=undefined`, `-fsanitize-trap=undefined` is now also
understood and is generally equivalent to `-fsanitize-c=trap` for
`zig build-exe`.

Due to this change, the `sanitize_c` field in the `std.Build` API had to
have its type changed from `?bool` to `?std.zig.SanitizeC`. If you were
setting this field to `true` or `false` previously, you\'ll now want
`.full` or `.off`, respectively, to get the same behavior.

### [Compile Tests to Object File](#toc-Compile-Tests-to-Object-File) [§](#Compile-Tests-to-Object-File){.hdr} {#Compile-Tests-to-Object-File}

Typically, Zig\'s testing functionality is used to build an executable
directly. However, there are situations in which you may want to build
tests without linking them into a final executable, such as for
integration with external code which loads your application as a shared
library. Zig 0.15.x facilitates such use cases by allowing an object
file to be emitted instead of a binary, and this object can then be
linked however is necessary.

On the CLI, this is represented by running `zig test-obj` instead of
`zig test`.

When using the build system, it is represented through a new `std.Build`
API. By passing the `emit_object` option to `std.Build.addTest`, you get
a `Step.Compile` which emits an object file, which you can then use that
as you would any other object. For instance, it can be installed for
external use, or it can be directly linked into another step. However,
note that when using this feature, the build runner does not communicate
with the test runner, falling back to the default `zig test` behavior of
reporting failed tests over stderr. Users of this feature will likely
want to override the test runner for the compilation as well, replacing
it with a custom one which communicates with some external test harness.

### [Zig Init](#toc-Zig-Init) [§](#Zig-Init){.hdr} {#Zig-Init}

The `zig init` command has a new template for creating projects.

The old template included code for generating a static library of a Zig
module, which caused some newcomers to mistakenly think that this was
the preferred way of sharing reusable Zig code.

The new template offers boilerplate for creating a Zig module and an
executable. This should cover most use cases, and it also shows how to
split logic between a reusable module and the application. Users that
only intend to create one kind of artifact can delete the extra code,
although the template should be considered a gentle reminder about:

- creating tooling for your libraries
- providing convenient access to reusable logic in your executables

You can now pass `--minimal` or `-m` to `zig init` to generate a
minimalistic template. Running the command will generate a
`build.zig.zon` file and, if not already present, a `build.zig` file
with just a stub of the `build` function. This option is intended for
those who are familiar with the Zig build system, and who mainly want a
convenient way of generating a Zon file with a correct fingerprint.

## [Linker](#toc-Linker) [§](#Linker){.hdr} {#Linker}

Zig\'s linker received only bug fixes and maintenance during this
release cycle. However, it will be a key focus in the [next release
cycle](#Roadmap) in order to improve [Incremental
Compilation](#Incremental-Compilation).

## [Fuzzer](#toc-Fuzzer) [§](#Fuzzer){.hdr} {#Fuzzer}

Although the core team remains enthusiastic about fuzzing, we did not
find the time to actively push forward on it during this release cycle.
We\'d like to acknowledge the efforts of contributor Kendall Condon who
opened a pull request [greatly improve capabilities of the
fuzzer](https://github.com/ziglang/zig/pull/23416), and is patiently
waiting for collaboration from the core team.

## [Bug Fixes](#toc-Bug-Fixes) [§](#Bug-Fixes){.hdr} {#Bug-Fixes}

[Full list of the 201 bug reports closed during this release
cycle](https://github.com/ziglang/zig/issues?q=is%3Aclosed+is%3Aissue+label%3Abug+milestone%3A0.15.0).

Many bugs were both introduced and resolved within this release cycle.
Most bug fixes are omitted from these release notes for the sake of
brevity.

### [This Release Contains Bugs](#toc-This-Release-Contains-Bugs) [§](#This-Release-Contains-Bugs){.hdr} {#This-Release-Contains-Bugs}

![Zero the
Ziguana](https://ziglang.org/img/Zero_8.svg){style="height: 13em; float: right"}

Zig has [known
bugs](https://github.com/ziglang/zig/issues?q=is%3Aopen+is%3Aissue+label%3Abug),
[miscompilations](https://github.com/ziglang/zig/issues?q=is%3Aopen+is%3Aissue+label%3Amiscompilation),
and
[regressions](https://github.com/ziglang/zig/issues?q=is%3Aopen+is%3Aissue+label%3Aregression).

Even with Zig 0.15.x, working on a non-trivial project using Zig may
require participating in the development process.

When Zig reaches 1.0.0, Tier 1 support will gain a bug policy as an
additional requirement.

## [Toolchain](#toc-Toolchain) [§](#Toolchain){.hdr} {#Toolchain}

### [LLVM 20](#toc-LLVM-20) [§](#LLVM-20){.hdr} {#LLVM-20}

This release of Zig upgrades to [LLVM
20.1.8](https://releases.llvm.org/20.1.0/docs/ReleaseNotes.html). This
covers Clang (`zig cc`/`zig c++`), libc++, libc++abi, libunwind, and
libtsan as well.

Zig now allows using LLVM\'s SPIR-V backend. Note that the self-hosted
SPIR-V backend remains the default. To use the LLVM backend, build with
`-fllvm`.

### [Support dynamically-linked FreeBSD libc when cross-compiling](#toc-Support-dynamically-linked-FreeBSD-libc-when-cross-compiling) [§](#Support-dynamically-linked-FreeBSD-libc-when-cross-compiling){.hdr} {#Support-dynamically-linked-FreeBSD-libc-when-cross-compiling}

Zig now allows cross-compiling to FreeBSD 14+ by providing stub
libraries for dynamic libc, similar to how cross-compilation for glibc
is handled. Additionally, all system and libc headers are provided.

### [Support dynamically-linked NetBSD libc when cross-compiling](#toc-Support-dynamically-linked-NetBSD-libc-when-cross-compiling) [§](#Support-dynamically-linked-NetBSD-libc-when-cross-compiling){.hdr} {#Support-dynamically-linked-NetBSD-libc-when-cross-compiling}

Zig now allows cross-compiling to NetBSD 10.1+ by providing stub
libraries for dynamic libc, similar to how cross-compilation for glibc
is handled. Additionally, all system and libc headers are provided.

### [glibc 2.42](#toc-glibc-242) [§](#glibc-242){.hdr} {#glibc-242}

glibc version 2.42 is now available when cross-compiling.

#### [Allow linking native glibc statically](#toc-Allow-linking-native-glibc-statically) [§](#Allow-linking-native-glibc-statically){.hdr} {#Allow-linking-native-glibc-statically}

Zig now permits linking against native glibc statically. This is not
generally a good idea, but can be fine in niche use cases that don\'t
rely on glibc functionality which internally requires dynamic linking
(for things such as NSS and `iconv`).

Note that this does not apply when cross-compiling using Zig\'s bundled
glibc as Zig only provides dynamic glibc.

### [MinGW-w64](#toc-MinGW-w64) [§](#MinGW-w64){.hdr} {#MinGW-w64}

This release bumps the bundled MinGW-w64 copy to commit
`38c8142f660b6ba11e7c408f2de1e9f8bfaf839e`.

### [zig libc](#toc-zig-libc) [§](#zig-libc){.hdr}

In this release, we\'ve started the effort to share code between the
statically-linked libcs that Zig provides---currently musl, wasi-libc,
and [MinGW-w64](#MinGW-w64)---by reimplementing common functions in Zig
code in the new zig libc library. This means that there is a single
canonical implementation of each function, and we\'re able to improve
the implementation without having to modify the vendored libc code from
the aforementioned projects. The *very* long term aspiration
here---which will require a *lot* of work---is to completely eliminate
our dependency on the upstream C implementation code of those libcs,
such that we ship only their headers.

This effort is contributor-friendly, so if this sounds interesting to
you, check out [issue #2879](https://github.com/ziglang/zig/issues/2879)
for details.

### [zig cc](#toc-zig-cc) [§](#zig-cc){.hdr}

zig cc now properly respects the -static and -dynamic flags. Most
notably, this allows statically linking native glibc, and dynamically
linking cross-compiled musl.

### [zig objcopy regressed](#toc-zig-objcopy-regressed) [§](#zig-objcopy-regressed){.hdr}

Sorry, the code was not up to quality standards and must be reworked.
Some functionality remains; other functionality errors with
\"unimplemented\". #24522

