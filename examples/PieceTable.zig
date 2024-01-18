const std = @import("std");
const testing = std.testing;

/// Represents buffer and a set of changes to the buffer.
///
/// All insertions are copied internally. Deletions to the buffer will not free memory.
///
/// To initialize without text, use struct initialization syntax and specify an allocator
/// like so: `var table = PieceTable{ .allocator = allocator };`
pub const PieceTable = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayListUnmanaged([]u8) = .{},
    pieces: std.ArrayListUnmanaged(Piece) = .{},

    pub const Piece = struct {
        slice: []const u8,
        tag: Tag = .added,
        pub const Tag = enum {
            original,
            added,
        };
    };

    pub fn init(allocator: std.mem.Allocator, original: []const u8) !PieceTable {
        if (original.len == 0) {
            // An empty string was passed, skip making a copy of it
            return .{
                .allocator = allocator,
            };
        }

        const original_copy = try allocator.dupe(u8, original);

        // Store original text
        var buffers = try std.ArrayListUnmanaged([]u8).initCapacity(allocator, 1);
        buffers.appendAssumeCapacity(original_copy);

        // Create piece pointing to original text
        var pieces = try std.ArrayListUnmanaged(Piece).initCapacity(allocator, 1);
        pieces.appendAssumeCapacity(.{
            .slice = original_copy,
            .tag = .original,
        });

        return .{
            .allocator = allocator,
            .buffers = buffers,
            .pieces = pieces,
        };
    }

    pub fn deinit(table: *PieceTable) void {
        for (table.buffers.items) |buffer| {
            table.allocator.free(buffer);
        }
        table.buffers.deinit(table.allocator);
        table.pieces.deinit(table.allocator);
    }

    /// Inserts `new_text` into buffer at `index`.
    ///
    /// `new_text` is owned by caller.
    ///
    /// It is an error to insert outside of the bounds of the piece table. If the
    /// table is empty, 0 is the only valid argument for index.
    pub fn insert(table: *PieceTable, index: usize, new_text: []const u8) !void {
        const text = try table.allocator.dupe(u8, new_text);
        try table.buffers.append(table.allocator, text);

        // Insert at the start of the file, catches empty tables
        if (index == 0) {
            try table.pieces.insert(table.allocator, 0, .{ .slice = text, .tag = .added });
            return;
        }

        var p_i: usize = 0;
        var b_i: usize = 0;
        while (p_i < table.pieces.items.len) : (p_i += 1) {
            const p = table.pieces.items[p_i];
            if (index == b_i + p.slice.len) {
                if (p_i + 1 == table.pieces.items.len) {
                    // The new index is the end of the file
                    try table.pieces.append(table.allocator, .{ .slice = text, .tag = .added });
                    return;
                } else {
                    // The new index is directly after an existing node, but not at the end of the file.
                    try table.pieces.insert(table.allocator, p_i + 1, .{ .slice = text, .tag = .added });
                    return;
                }
            } else if (index < b_i + p.slice.len) {
                // new piece is within another piece; split the old one into 2
                // and insert the new piece between

                // ignore the returned slice since we will also want the
                // piece right before the insertion
                _ = try table.pieces.addManyAt(table.allocator, p_i + 1, 2);
                const pieces = table.pieces.items[p_i..][0..3];

                const sub_i = index - b_i;

                pieces[0].slice = p.slice[0..sub_i];
                pieces[1].slice = text;
                pieces[2].slice = p.slice[sub_i..];

                // set the tag for the pieces 1 and 2
                // elide setting the tag for pieces[0], it should be correct already
                pieces[1].tag = .added;
                switch (p.tag) {
                    .original => pieces[2].tag = .original,
                    .added => pieces[2].tag = .added,
                }
                return;
            } else {
                b_i += p.slice.len;
            }
        }

        @panic("Impossible state while inserting into PieceTable");
    }

    /// Deletes the data from start to start+length from the piece table.
    /// Will not free any memory.
    pub fn delete(table: *PieceTable, start: usize, length: usize) !void {
        if (length == 0) return error.InvalidLength;
        const endi = start + length;

        var b_i: usize = 0; // buffer index
        const p_start, const start_subi, const start_piece = for (table.pieces.items, 0..) |piece, i| {
            if (start < b_i + piece.slice.len) {
                // start found
                break .{ i, start - b_i, piece };
            }
            b_i += piece.slice.len;
        } else return error.OutOfBounds;

        // reuse b_i
        const p_end, const end_subi, const end_piece = for (table.pieces.items[p_start..], p_start..) |piece, i| {
            if (endi < b_i + piece.slice.len) {
                break .{ i, endi - b_i, piece };
            }
            b_i += piece.slice.len;
        } else .{ p_start, start_piece.slice.len, start_piece };

        // Removal cases:
        // 1. the deletion starts on one piece boundary and ends on another piece boundary
        //     - Delete all pieces between start and end
        // 2. the deletion starts within a piece and ends on a boundary
        //     - Delete all but the start piece
        //     - modify slice end in start piece
        // 3. the deletion starts on a bondary and ends within a piece
        //     - Delete all but the end piece
        //     - modify slice start in end piece
        // 4. the deletion starts within a piece and ends within a piece
        //     - Delet all the start and end pieces
        //     - modify slice end in start piece
        //     - modify slice end in end piece

        const is_start_on_boundary = start_subi == 0;
        const is_end_on_boundary = end_subi == end_piece.slice.len;

        const remove_len = (p_end + 1) - p_start;
        if (is_start_on_boundary and is_end_on_boundary) {
            table.pieces.replaceRange(table.allocator, p_start, remove_len, &.{}) catch unreachable;
        } else {
            if (is_start_on_boundary) {
                const new = &[_]PieceTable.Piece{
                    .{ .slice = end_piece.slice[end_subi..], .tag = end_piece.tag },
                };
                table.pieces.replaceRange(table.allocator, p_start, remove_len, new) catch unreachable;
            } else if (is_end_on_boundary) {
                const new = &[_]PieceTable.Piece{
                    .{ .slice = start_piece.slice[0..start_subi], .tag = start_piece.tag },
                };
                table.pieces.replaceRange(table.allocator, p_start, remove_len, new) catch unreachable;
            } else {
                const new = &[_]PieceTable.Piece{
                    .{ .slice = start_piece.slice[0..start_subi], .tag = start_piece.tag },
                    .{ .slice = end_piece.slice[end_subi..], .tag = end_piece.tag },
                };
                table.pieces.replaceRange(table.allocator, p_start, remove_len, new) catch unreachable;
            }
        }
    }

    pub fn getTotalSize(table: PieceTable) usize {
        var length: usize = 0;
        for (table.pieces.items) |piece| {
            length += piece.slice.len;
        }
        return length;
    }

    pub fn writeAll(table: PieceTable, buffer: []u8) void {
        std.debug.assert(table.getTotalSize() == buffer.len);
        var current_buffer = buffer[0..];
        for (table.pieces.items) |piece| {
            @memcpy(current_buffer[0..piece.slice.len], piece.slice);
            current_buffer = current_buffer[piece.slice.len..];
        }
    }

    pub fn writeAllAlloc(table: PieceTable) ![]u8 {
        const size = table.getTotalSize();
        const buffer = try table.allocator.alloc(u8, size);
        var current_buffer = buffer[0..];
        for (table.pieces.items) |piece| {
            @memcpy(current_buffer[0..piece.slice.len], piece.slice);
            current_buffer = current_buffer[piece.slice.len..];
        }
        return buffer;
    }
};

test "Init empty PieceTable" {
    var table = try PieceTable.init(testing.allocator, "");
    defer table.deinit();

    var out_buf: [0]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings("", &out_buf);
}

test "Insert into empty PieceTable" {
    var table = try PieceTable.init(testing.allocator, "");
    defer table.deinit();

    try table.insert(0, "the quick brown fox\njumped over the lazy dog");

    var out_buf: [44]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\jumped over the lazy dog
    , &out_buf);
}

test "Init Piecetable" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    var out_buf: [44]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\jumped over the lazy dog
    , &out_buf);
}

test "Insert into PieceTable" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");

    try testing.expectEqual(@as(usize, 3), table.pieces.items.len);
    try testing.expectEqual(PieceTable.Piece.Tag.original, table.pieces.items[0].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.added, table.pieces.items[1].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.original, table.pieces.items[2].tag);

    try testing.expectEqualStrings("the quick brown fox\n", table.pieces.items[0].slice);
    try testing.expectEqualStrings("went to the park and\n", table.pieces.items[1].slice);
    try testing.expectEqualStrings("jumped over the lazy dog", table.pieces.items[2].slice);

    try testing.expectEqual(@as(usize, 65), table.getTotalSize());

    var out_buf: [65]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\went to the park and
        \\jumped over the lazy dog
    , &out_buf);
}

test "Insert at end of Piece" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");
    try table.insert(41, "ate a burger and\n");

    try testing.expectEqual(@as(usize, 4), table.pieces.items.len);
    try testing.expectEqual(PieceTable.Piece.Tag.original, table.pieces.items[0].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.added, table.pieces.items[1].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.added, table.pieces.items[2].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.original, table.pieces.items[3].tag);

    try testing.expectEqualStrings("the quick brown fox\n", table.pieces.items[0].slice);
    try testing.expectEqualStrings("went to the park and\n", table.pieces.items[1].slice);
    try testing.expectEqualStrings("ate a burger and\n", table.pieces.items[2].slice);
    try testing.expectEqualStrings("jumped over the lazy dog", table.pieces.items[3].slice);

    try testing.expectEqual(@as(usize, 82), table.getTotalSize());

    var out_buf: [82]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\went to the park and
        \\ate a burger and
        \\jumped over the lazy dog
    , &out_buf);
}

test "Insert at end of file" {
    const original = "the quick brown fox";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(19, "\njumped over the lazy dog");

    try testing.expectEqual(@as(usize, 2), table.pieces.items.len);
    try testing.expectEqual(PieceTable.Piece.Tag.original, table.pieces.items[0].tag);
    try testing.expectEqual(PieceTable.Piece.Tag.added, table.pieces.items[1].tag);

    try testing.expectEqualStrings("the quick brown fox", table.pieces.items[0].slice);
    try testing.expectEqualStrings("\njumped over the lazy dog", table.pieces.items[1].slice);

    try testing.expectEqual(@as(usize, 44), table.getTotalSize());

    var out_buf: [44]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\jumped over the lazy dog
    , &out_buf);
}

test "Delete one entire Piece" {
    const original = "the quick brown fox";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.delete(0, 19);
    try testing.expectEqual(@as(usize, 0), table.pieces.items.len);
}

test "Delete multiple entire Pieces" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");
    try table.insert(41, "ate a burger and\n");
    try table.delete(20, 38);

    try testing.expectEqual(@as(usize, 2), table.pieces.items.len);
}

test "Delete inside a Piece" {
    const original = "the quick brown fox";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    // delete "brown "
    try table.delete(10, 6);

    try testing.expectEqual(@as(usize, 2), table.pieces.items.len);
    try testing.expectEqualStrings("the quick ", table.pieces.items[0].slice);
    try testing.expectEqualStrings("fox", table.pieces.items[1].slice);

    try testing.expectEqual(@as(usize, 13), table.getTotalSize());

    var out_buf: [13]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick fox
    , &out_buf);
}

test "Delete from within one piece to within another piece" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");
    try table.insert(41, "ate a burger and\n");
    try table.delete(45, 13 + 12);

    try testing.expectEqual(@as(usize, 4), table.pieces.items.len);

    try testing.expectEqual(@as(usize, 57), table.getTotalSize());

    var out_buf: [57]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\went to the park and
        \\ate the lazy dog
    , &out_buf);
}

test "Delete from start of piece to within piece" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");
    try table.insert(41, "ate a burger and\n");
    try table.delete(41, 13);

    try testing.expectEqual(@as(usize, 4), table.pieces.items.len);

    try testing.expectEqual(@as(usize, 69), table.getTotalSize());

    var out_buf: [69]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\went to the park and
        \\and
        \\jumped over the lazy dog
    , &out_buf);
}

test "Delete from within piece to end of piece" {
    const original = "the quick brown fox\njumped over the lazy dog";
    var table = try PieceTable.init(testing.allocator, original);
    defer table.deinit();

    try table.insert(20, "went to the park and\n");
    try table.insert(41, "ate a burger and\n");
    try table.delete(45, 13);

    try testing.expectEqual(@as(usize, 4), table.pieces.items.len);

    try testing.expectEqual(@as(usize, 69), table.getTotalSize());

    var out_buf: [69]u8 = undefined;
    table.writeAll(&out_buf);

    try testing.expectEqualStrings(
        \\the quick brown fox
        \\went to the park and
        \\ate jumped over the lazy dog
    , &out_buf);
}
