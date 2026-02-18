const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// A writer wrapper that counts the number of bytes written while forwarding
/// all writes to the underlying writer. This is a drop-in replacement for the
/// removed `std.io.countingWriter`.
///
/// Usage:
/// ```
/// var cw = countingWriter(some_writer);
/// const writer = cw.writer();
/// try writer.writeAll("hello");
/// std.debug.print("bytes written: {}\n", .{cw.bytes_written});
/// ```
pub fn CountingWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        pub const Error = WriterType.Error;
        pub const Writer = std.io.GenericWriter(*Self, Error, write);

        bytes_written: u64 = 0,
        child_stream: WriterType,

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            const amt = try self.child_stream.write(bytes);
            self.bytes_written += amt;
            return amt;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

/// Creates a `CountingWriter` that wraps the given writer, counting all bytes
/// written through it while forwarding to the underlying stream.
pub fn countingWriter(child_stream: anytype) CountingWriter(@TypeOf(child_stream)) {
    return .{ .child_stream = child_stream };
}

/// A double-ended queue (deque) backed by a growable ring buffer, similar to
/// Rust's `std::collections::VecDeque`.
///
/// Internally uses a dynamically-sized circular buffer (with ArrayList-style
/// growth) to allow efficient O(1) amortized push and pop operations at both
/// ends.
///
/// Usage:
/// ```
/// var deque = VecDeque(u32).empty;
/// defer deque.deinit(allocator);
/// try deque.pushBack(allocator, 1);
/// try deque.pushFront(allocator, 0);
/// _ = deque.popFront(); // 0
/// _ = deque.popBack();  // 1
/// ```
pub fn VecDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying ring buffer storage.
        buf: std.ArrayListUnmanaged(T) = .empty,
        /// Index of the first (front) element in the ring buffer.
        head: usize = 0,
        /// Number of elements currently stored in the deque.
        count: usize = 0,

        /// An empty deque, requiring no allocation.
        pub const empty: Self = .{};

        /// Release all allocated memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.buf.deinit(allocator);
            self.* = undefined;
        }

        /// Returns the total number of elements the deque can hold without
        /// reallocating.
        pub fn capacity(self: *const Self) usize {
            return self.buf.capacity;
        }

        /// Returns the number of elements in the deque.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Returns `true` if the deque contains no elements.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Ensures there is enough capacity for at least `min_capacity`
        /// total elements.
        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, min_capacity: usize) Allocator.Error!void {
            if (self.buf.capacity >= min_capacity) return;
            try self.grow(allocator, min_capacity);
        }

        /// Ensures there is enough capacity for `additional` more elements
        /// beyond the current count.
        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, additional: usize) Allocator.Error!void {
            return self.ensureTotalCapacity(allocator, self.count + additional);
        }

        /// Appends an element to the back of the deque.
        pub fn pushBack(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, self.count + 1);
            self.pushBackAssumeCapacity(item);
        }

        /// Appends an element to the back without checking capacity.
        pub fn pushBackAssumeCapacity(self: *Self, item: T) void {
            assert(self.count < self.buf.capacity);
            self.ringBuf()[self.wrapIndex(self.head + self.count)] = item;
            self.count += 1;
        }

        /// Prepends an element to the front of the deque.
        pub fn pushFront(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, self.count + 1);
            self.pushFrontAssumeCapacity(item);
        }

        /// Prepends an element to the front without checking capacity.
        pub fn pushFrontAssumeCapacity(self: *Self, item: T) void {
            assert(self.count < self.buf.capacity);
            self.head = self.wrapSub(self.head, 1);
            self.ringBuf()[self.head] = item;
            self.count += 1;
        }

        /// Removes and returns the front element, or `null` if empty.
        pub fn popFront(self: *Self) ?T {
            if (self.count == 0) return null;
            const item = self.ringBuf()[self.head];
            self.head = self.wrapIndex(self.head + 1);
            self.count -= 1;
            return item;
        }

        /// Removes and returns the back element, or `null` if empty.
        pub fn popBack(self: *Self) ?T {
            if (self.count == 0) return null;
            self.count -= 1;
            return self.ringBuf()[self.wrapIndex(self.head + self.count)];
        }

        /// Returns the front element without removing it, or `null` if empty.
        pub fn peekFront(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.constRingBuf()[self.head];
        }

        /// Returns the back element without removing it, or `null` if empty.
        pub fn peekBack(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.constRingBuf()[self.wrapIndex(self.head + self.count - 1)];
        }

        /// Returns the element at logical `index` (0 = front), or `null` if
        /// out of bounds.
        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.count) return null;
            return self.constRingBuf()[self.wrapIndex(self.head + index)];
        }

        /// Sets the element at logical `index` (0 = front).
        /// Asserts that the index is within bounds.
        pub fn set(self: *Self, index: usize, value: T) void {
            assert(index < self.count);
            self.ringBuf()[self.wrapIndex(self.head + index)] = value;
        }

        /// Removes all elements from the deque without releasing memory.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        /// Removes all elements and releases all allocated memory.
        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            self.buf.clearAndFree(allocator);
            self.head = 0;
            self.count = 0;
        }

        /// Returns the two contiguous slices that make up the deque contents.
        /// The first slice is from head to the end-of-buffer (or tail),
        /// and the second slice wraps around from the start of the buffer
        /// (empty if the data is contiguous).
        pub fn slices(self: *const Self) struct { []const T, []const T } {
            if (self.count == 0) return .{ &.{}, &.{} };
            const cap = self.buf.capacity;
            const ring = self.constRingBuf();
            const tail = self.head + self.count;
            if (tail <= cap) {
                // contiguous
                return .{ ring[self.head..tail], &.{} };
            } else {
                // wraps around
                return .{ ring[self.head..cap], ring[0 .. tail - cap] };
            }
        }

        /// Appends a single item. Compatible with the old `LinearFifo.writeItem`.
        pub fn writeItem(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            return self.pushBack(allocator, item);
        }

        /// Pops the front item. Compatible with the old `LinearFifo.readItem`.
        pub fn readItem(self: *Self) ?T {
            return self.popFront();
        }

        /// Access the full allocated capacity as a mutable slice.
        fn ringBuf(self: *Self) []T {
            return self.buf.items.ptr[0..self.buf.capacity];
        }

        /// Access the full allocated capacity as a const slice.
        fn constRingBuf(self: *const Self) []const T {
            return self.buf.items.ptr[0..self.buf.capacity];
        }

        /// Wraps an index into the ring buffer range [0, capacity).
        fn wrapIndex(self: *const Self, idx: usize) usize {
            return idx % self.buf.capacity;
        }

        /// Subtracts `n` from `idx` with wrap-around in the ring buffer.
        fn wrapSub(self: *const Self, idx: usize, n: usize) usize {
            if (idx >= n) return idx - n;
            return self.buf.capacity - (n - idx);
        }

        /// Grows the ring buffer to at least `min_capacity`, linearizing
        /// the contents so that `head` resets to 0.
        fn grow(self: *Self, allocator: Allocator, min_capacity: usize) Allocator.Error!void {
            const old_cap = self.buf.capacity;
            // Use ArrayList-style growth: at least double, or the requested min.
            const new_cap = @max(
                if (old_cap == 0) @as(usize, 4) else old_cap * 2,
                min_capacity,
            );

            // Allocate new buffer via a fresh ArrayList.
            var new_buf: std.ArrayListUnmanaged(T) = .empty;
            try new_buf.ensureTotalCapacityPrecise(allocator, new_cap);

            // Copy elements in logical order into the new buffer, linearising.
            if (self.count > 0) {
                const old_ring = self.buf.items.ptr[0..old_cap];
                const new_ring = new_buf.items.ptr[0..new_cap];
                const tail = self.head + self.count;
                if (tail <= old_cap) {
                    // Contiguous – single memcpy.
                    @memcpy(new_ring[0..self.count], old_ring[self.head..tail]);
                } else {
                    // Wrapped – two memcpy operations.
                    const first_len = old_cap - self.head;
                    @memcpy(new_ring[0..first_len], old_ring[self.head..old_cap]);
                    @memcpy(new_ring[first_len..self.count], old_ring[0 .. self.count - first_len]);
                }
            }

            // Free old buffer and install new one.
            self.buf.deinit(allocator);
            self.buf = new_buf;
            self.head = 0;
        }
    };
}

test "CountingWriter counts bytes correctly" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var cw = countingWriter(stream.writer());
    const writer = cw.writer();

    try writer.writeAll("hello");
    try std.testing.expectEqual(@as(u64, 5), cw.bytes_written);

    try writer.writeAll(" world");
    try std.testing.expectEqual(@as(u64, 11), cw.bytes_written);
}

test "CountingWriter with null_writer" {
    var cw = countingWriter(std.io.null_writer);
    const writer = cw.writer();

    try writer.writeAll("invisible");
    try std.testing.expectEqual(@as(u64, 9), cw.bytes_written);
}

test "VecDeque pushBack and popFront" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    try dq.pushBack(allocator, 1);
    try dq.pushBack(allocator, 2);
    try dq.pushBack(allocator, 3);

    try std.testing.expectEqual(@as(usize, 3), dq.len());
    try std.testing.expectEqual(@as(u32, 1), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 2), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 3), dq.popFront().?);
    try std.testing.expectEqual(@as(?u32, null), dq.popFront());
}

test "VecDeque pushFront and popBack" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    try dq.pushFront(allocator, 1);
    try dq.pushFront(allocator, 2);
    try dq.pushFront(allocator, 3);

    try std.testing.expectEqual(@as(u32, 1), dq.popBack().?);
    try std.testing.expectEqual(@as(u32, 2), dq.popBack().?);
    try std.testing.expectEqual(@as(u32, 3), dq.popBack().?);
}

test "VecDeque mixed push/pop with wrap-around" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    // Fill to force initial capacity (4)
    try dq.pushBack(allocator, 10);
    try dq.pushBack(allocator, 20);
    try dq.pushBack(allocator, 30);
    try dq.pushBack(allocator, 40);

    // Pop two from front – head advances into the buffer
    try std.testing.expectEqual(@as(u32, 10), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 20), dq.popFront().?);

    // Push two more – they should wrap around
    try dq.pushBack(allocator, 50);
    try dq.pushBack(allocator, 60);

    try std.testing.expectEqual(@as(usize, 4), dq.len());
    try std.testing.expectEqual(@as(u32, 30), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 40), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 50), dq.popFront().?);
    try std.testing.expectEqual(@as(u32, 60), dq.popFront().?);
}

test "VecDeque dynamic growth with wrap-around data" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    // Push 4 items, pop 2 from front so head != 0
    for (0..4) |i| try dq.pushBack(allocator, @intCast(i));
    _ = dq.popFront();
    _ = dq.popFront();

    // Now push enough to trigger growth while data wraps
    for (4..10) |i| try dq.pushBack(allocator, @intCast(i));

    // Verify order is maintained after growth
    for (2..10) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), dq.popFront().?);
    }
}

test "VecDeque peek and random access" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    try dq.pushBack(allocator, 100);
    try dq.pushBack(allocator, 200);
    try dq.pushBack(allocator, 300);

    try std.testing.expectEqual(@as(u32, 100), dq.peekFront().?);
    try std.testing.expectEqual(@as(u32, 300), dq.peekBack().?);
    try std.testing.expectEqual(@as(u32, 200), dq.get(1).?);
    try std.testing.expectEqual(@as(?u32, null), dq.get(3));
}

test "VecDeque slices" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u8).empty;
    defer dq.deinit(allocator);

    // Push and pop to create wrap-around
    try dq.pushBack(allocator, 'a');
    try dq.pushBack(allocator, 'b');
    try dq.pushBack(allocator, 'c');
    try dq.pushBack(allocator, 'd');
    _ = dq.popFront(); // remove 'a', head = 1
    _ = dq.popFront(); // remove 'b', head = 2
    try dq.pushBack(allocator, 'e');
    try dq.pushBack(allocator, 'f');
    // Now: ring = [e, f, c, d], head=2, count=4 → wraps around

    const pair = dq.slices();
    try std.testing.expectEqualSlices(u8, &.{ 'c', 'd' }, pair[0]);
    try std.testing.expectEqualSlices(u8, &.{ 'e', 'f' }, pair[1]);
}

test "VecDeque writeItem/readItem compatibility" {
    const allocator = std.testing.allocator;
    var dq = VecDeque(u32).empty;
    defer dq.deinit(allocator);

    try dq.writeItem(allocator, 1);
    try dq.writeItem(allocator, 2);
    try dq.writeItem(allocator, 3);

    try std.testing.expectEqual(@as(u32, 1), dq.readItem().?);
    try std.testing.expectEqual(@as(u32, 2), dq.readItem().?);
    try std.testing.expectEqual(@as(u32, 3), dq.readItem().?);
    try std.testing.expectEqual(@as(?u32, null), dq.readItem());
}
