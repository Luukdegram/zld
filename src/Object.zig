const Object = @This();

const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log.scoped(.object);
const macho = std.macho;
const mem = std.mem;

const Allocator = mem.Allocator;
const parseName = @import("Zld.zig").parseName;

usingnamespace @import("commands.zig");

allocator: *Allocator,
file: fs.File,
name: []u8,

header: macho.mach_header_64,

load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},

segment_cmd_index: ?u16 = null,
symtab_cmd_index: ?u16 = null,
dysymtab_cmd_index: ?u16 = null,
build_version_cmd_index: ?u16 = null,

text_section_index: ?u16 = null,

dwarf_debug_info_index: ?u16 = null,
dwarf_debug_abbrev_index: ?u16 = null,
dwarf_debug_str_index: ?u16 = null,
dwarf_debug_line_index: ?u16 = null,
dwarf_debug_ranges_index: ?u16 = null,

symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: std.ArrayListUnmanaged(u8) = .{},

directory: std.AutoHashMapUnmanaged(DirectoryKey, u16) = .{},

pub const DirectoryKey = struct {
    segname: [16]u8,
    sectname: [16]u8,
};

pub fn deinit(self: *Object) void {
    for (self.load_commands.items) |*lc| {
        lc.deinit(self.allocator);
    }
    self.load_commands.deinit(self.allocator);
    self.symtab.deinit(self.allocator);
    self.strtab.deinit(self.allocator);
    self.directory.deinit(self.allocator);
    self.allocator.free(self.name);
    self.file.close();
}

/// Caller owns the returned Object instance and is responsible for calling
/// `deinit` to free allocated memory.
pub fn initFromFile(allocator: *Allocator, name: []const u8, file: fs.File) !Object {
    var reader = file.reader();
    const header = try reader.readStruct(macho.mach_header_64);

    if (header.filetype != macho.MH_OBJECT) {
        // Reset file cursor.
        try file.seekTo(0);
        return error.NotObject;
    }

    var self = Object{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .file = file,
        .header = header,
    };

    try self.load_commands.ensureCapacity(self.allocator, self.header.ncmds);

    var i: u16 = 0;
    while (i < self.header.ncmds) : (i += 1) {
        const cmd = try LoadCommand.read(self.allocator, reader);
        switch (cmd.cmd()) {
            macho.LC_SEGMENT_64 => {
                self.segment_cmd_index = i;
                const seg = cmd.Segment;
                for (seg.sections.items) |sect, j| {
                    const index = @intCast(u16, j);
                    const segname = parseName(&sect.segname);
                    const sectname = parseName(&sect.sectname);
                    if (mem.eql(u8, segname, "__DWARF")) {
                        if (mem.eql(u8, sectname, "__debug_info")) {
                            self.dwarf_debug_info_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_abbrev")) {
                            self.dwarf_debug_abbrev_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_str")) {
                            self.dwarf_debug_str_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_line")) {
                            self.dwarf_debug_line_index = index;
                        } else if (mem.eql(u8, sectname, "__debug_ranges")) {
                            self.dwarf_debug_ranges_index = index;
                        }
                    } else if (mem.eql(u8, segname, "__TEXT")) {
                        if (mem.eql(u8, sectname, "__text")) {
                            self.text_section_index = index;
                        }
                    }

                    try self.directory.putNoClobber(self.allocator, .{
                        .segname = sect.segname,
                        .sectname = sect.sectname,
                    }, index);
                }
            },
            macho.LC_SYMTAB => {
                self.symtab_cmd_index = i;
            },
            macho.LC_DYSYMTAB => {
                self.dysymtab_cmd_index = i;
            },
            macho.LC_BUILD_VERSION => {
                self.build_version_cmd_index = i;
            },
            else => {
                log.warn("Unknown load command detected: 0x{x}.", .{cmd.cmd()});
            },
        }
        self.load_commands.appendAssumeCapacity(cmd);
    }

    try self.parseSymtab();
    try self.parseStrtab();

    return self;
}

fn parseSymtab(self: *Object) !void {
    const symtab_cmd = self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    var buffer = try self.allocator.alloc(u8, @sizeOf(macho.nlist_64) * symtab_cmd.nsyms);
    defer self.allocator.free(buffer);
    _ = try self.file.preadAll(buffer, symtab_cmd.symoff);
    try self.symtab.ensureCapacity(self.allocator, symtab_cmd.nsyms);
    // TODO this align case should not be needed.
    // Probably a bug in stage1.
    const slice = @alignCast(@alignOf(macho.nlist_64), mem.bytesAsSlice(macho.nlist_64, buffer));
    self.symtab.appendSliceAssumeCapacity(slice);
}

fn parseStrtab(self: *Object) !void {
    const symtab_cmd = self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    var buffer = try self.allocator.alloc(u8, symtab_cmd.strsize);
    defer self.allocator.free(buffer);
    _ = try self.file.preadAll(buffer, symtab_cmd.stroff);
    try self.strtab.ensureCapacity(self.allocator, symtab_cmd.strsize);
    self.strtab.appendSliceAssumeCapacity(buffer);
}

pub fn getString(self: *const Object, str_off: u32) []const u8 {
    assert(str_off < self.strtab.items.len);
    return mem.spanZ(@ptrCast([*:0]const u8, self.strtab.items.ptr + str_off));
}

pub fn parseSection(self: Object, allocator: *Allocator, index: u16) ![]u8 {
    const seg = self.load_commands.items[self.segment_cmd_index.?].Segment;
    const sect = seg.sections.items[index];
    var buffer = try allocator.alloc(u8, sect.size);
    _ = try self.file.preadAll(buffer, sect.offset);
    return buffer;
}
