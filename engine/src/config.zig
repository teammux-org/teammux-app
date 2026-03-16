const std = @import("std");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const AgentType = enum(c_int) {
    claude_code = 0,
    codex_cli = 1,
    custom = 99,

    pub fn fromString(s: []const u8) AgentType {
        if (std.mem.eql(u8, s, "claude-code")) return .claude_code;
        if (std.mem.eql(u8, s, "codex-cli")) return .codex_cli;
        return .custom;
    }
};

pub const WorkerConfig = struct {
    id: []const u8,
    name: []const u8,
    agent: AgentType,
    model: []const u8,
    permissions: []const u8,
    default_task: []const u8,
    role: ?[]const u8 = null,
    role_path: ?[]const u8 = null,
};

pub const TeamLeadConfig = struct {
    agent: AgentType,
    model: []const u8,
    permissions: []const u8,
};

pub const ProjectConfig = struct {
    name: []const u8,
    github_repo: ?[]const u8,
};

pub const FieldsSet = struct {
    tl_model: bool = false,
    tl_permissions: bool = false,
    github_token: bool = false,
    bus_delivery: bool = false,
};

pub const Config = struct {
    project: ProjectConfig,
    team_lead: TeamLeadConfig,
    workers: []WorkerConfig,
    github_token: ?[]const u8,
    bus_delivery: []const u8,
    fields_set: FieldsSet = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.project.name);
        if (self.project.github_repo) |r| allocator.free(r);
        allocator.free(self.team_lead.model);
        allocator.free(self.team_lead.permissions);
        for (self.workers) |w| {
            allocator.free(w.id);
            allocator.free(w.name);
            allocator.free(w.model);
            allocator.free(w.permissions);
            allocator.free(w.default_task);
            if (w.role) |r| allocator.free(r);
            if (w.role_path) |rp| allocator.free(rp);
        }
        allocator.free(self.workers);
        if (self.github_token) |t| allocator.free(t);
        allocator.free(self.bus_delivery);
    }
};

// ─────────────────────────────────────────────────────────
// TOML Parser
// ─────────────────────────────────────────────────────────

const Section = enum { none, project, team_lead, workers, github, bus };

pub const ParseError = error{
    InvalidSyntax,
    UnknownSection,
    OutOfMemory,
};

/// Parse TOML content into a Config struct.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) ParseError!Config {
    var current_section: Section = .none;
    var workers: std.ArrayList(WorkerConfig) = .{};
    errdefer {
        for (workers.items) |w| {
            allocator.free(w.id);
            allocator.free(w.name);
            allocator.free(w.model);
            allocator.free(w.permissions);
            allocator.free(w.default_task);
            if (w.role) |r| allocator.free(r);
            if (w.role_path) |rp| allocator.free(rp);
        }
        workers.deinit(allocator);
    }

    // Defaults
    var project_name: []const u8 = try allocator.dupe(u8, "");
    var project_github_repo: ?[]const u8 = null;
    var tl_agent: AgentType = .claude_code;
    var tl_model: []const u8 = try allocator.dupe(u8, "claude-opus-4-6");
    var tl_permissions: []const u8 = try allocator.dupe(u8, "full");
    var github_token: ?[]const u8 = null;
    var bus_delivery: []const u8 = try allocator.dupe(u8, "guaranteed");

    // Track if defaults were replaced to avoid double-free
    var replaced_project_name = false;
    var replaced_tl_model = false;
    var replaced_tl_permissions = false;
    var replaced_bus_delivery = false;

    errdefer {
        allocator.free(project_name);
        if (project_github_repo) |r| allocator.free(r);
        if (!replaced_tl_model) allocator.free(tl_model);
        if (!replaced_tl_permissions) allocator.free(tl_permissions);
        if (github_token) |t| allocator.free(t);
        if (!replaced_bus_delivery) allocator.free(bus_delivery);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Array of tables: [[section]]
        if (line.len >= 4 and line[0] == '[' and line[1] == '[') {
            const end = std.mem.indexOf(u8, line, "]]") orelse continue;
            const section_name = std.mem.trim(u8, line[2..end], &[_]u8{ ' ', '\t' });
            if (std.mem.eql(u8, section_name, "workers")) {
                current_section = .workers;
                try workers.append(allocator, .{
                    .id = try allocator.dupe(u8, ""),
                    .name = try allocator.dupe(u8, ""),
                    .agent = .claude_code,
                    .model = try allocator.dupe(u8, "claude-sonnet-4-6"),
                    .permissions = try allocator.dupe(u8, "full"),
                    .default_task = try allocator.dupe(u8, ""),
                });
            }
            continue;
        }

        // Table: [section]
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section_name = std.mem.trim(u8, line[1..end], &[_]u8{ ' ', '\t' });
            if (std.mem.eql(u8, section_name, "project")) {
                current_section = .project;
            } else if (std.mem.eql(u8, section_name, "team_lead")) {
                current_section = .team_lead;
            } else if (std.mem.eql(u8, section_name, "github")) {
                current_section = .github;
            } else if (std.mem.eql(u8, section_name, "bus")) {
                current_section = .bus;
            } else {
                std.log.warn("[teammux] config: unknown section [{s}], keys will be ignored", .{section_name});
                current_section = .none;
            }
            continue;
        }

        // Key = value
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], &[_]u8{ ' ', '\t' });
        const raw_val = std.mem.trim(u8, line[eq_idx + 1 ..], &[_]u8{ ' ', '\t' });

        // Strip inline comments (only outside quotes)
        const val = stripValue(raw_val);

        switch (current_section) {
            .project => {
                if (std.mem.eql(u8, key, "name")) {
                    allocator.free(project_name);
                    replaced_project_name = true;
                    project_name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "github_repo")) {
                    if (project_github_repo) |old| allocator.free(old);
                    project_github_repo = try allocator.dupe(u8, val);
                }
            },
            .team_lead => {
                if (std.mem.eql(u8, key, "agent")) {
                    tl_agent = AgentType.fromString(val);
                } else if (std.mem.eql(u8, key, "model")) {
                    allocator.free(tl_model);
                    replaced_tl_model = true;
                    tl_model = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "permissions")) {
                    allocator.free(tl_permissions);
                    replaced_tl_permissions = true;
                    tl_permissions = try allocator.dupe(u8, val);
                }
            },
            .workers => {
                if (workers.items.len == 0) continue;
                const w = &workers.items[workers.items.len - 1];
                if (std.mem.eql(u8, key, "id")) {
                    allocator.free(w.id);
                    w.id = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "name")) {
                    allocator.free(w.name);
                    w.name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "agent")) {
                    w.agent = AgentType.fromString(val);
                } else if (std.mem.eql(u8, key, "model")) {
                    allocator.free(w.model);
                    w.model = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "permissions")) {
                    allocator.free(w.permissions);
                    w.permissions = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "default_task")) {
                    allocator.free(w.default_task);
                    w.default_task = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "role")) {
                    if (w.role) |old| allocator.free(old);
                    w.role = try allocator.dupe(u8, val);
                }
            },
            .github => {
                if (std.mem.eql(u8, key, "token")) {
                    if (github_token) |old| allocator.free(old);
                    github_token = try allocator.dupe(u8, val);
                }
            },
            .bus => {
                if (std.mem.eql(u8, key, "delivery")) {
                    allocator.free(bus_delivery);
                    replaced_bus_delivery = true;
                    bus_delivery = try allocator.dupe(u8, val);
                }
            },
            .none => {},
        }
    }

    return Config{
        .project = .{
            .name = project_name,
            .github_repo = project_github_repo,
        },
        .team_lead = .{
            .agent = tl_agent,
            .model = tl_model,
            .permissions = tl_permissions,
        },
        .workers = try workers.toOwnedSlice(allocator),
        .github_token = github_token,
        .bus_delivery = bus_delivery,
        .fields_set = .{
            .tl_model = replaced_tl_model,
            .tl_permissions = replaced_tl_permissions,
            .github_token = github_token != null,
            .bus_delivery = replaced_bus_delivery,
        },
    };
}

/// Strip quotes from a TOML value and remove inline comments.
fn stripValue(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;

    // Quoted string
    if (raw[0] == '"') {
        if (raw.len >= 2) {
            // Find closing quote
            if (std.mem.indexOfScalarPos(u8, raw, 1, '"')) |end| {
                return raw[1..end];
            }
        }
        return raw[1..];
    }

    // Bare value — strip inline comment
    if (std.mem.indexOfScalar(u8, raw, '#')) |hash_idx| {
        return std.mem.trim(u8, raw[0..hash_idx], &[_]u8{ ' ', '\t' });
    }
    return raw;
}

// ─────────────────────────────────────────────────────────
// TOML helpers for role parsing
// ─────────────────────────────────────────────────────────

const RoleSection = enum { none, identity, capabilities, triggers_on, context };

/// Parse a boolean TOML value. Returns null if not a valid boolean.
fn parseTomlBool(raw: []const u8) ?bool {
    const val = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t' });
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return null;
}

/// Parse a TOML inline array from a value string like `["a", "b", "c"]`.
/// Returns owned slice of owned strings. Caller must free each string and the slice.
fn parseTomlInlineArray(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t' });
    if (trimmed.len < 2 or trimmed[0] != '[') return allocator.alloc([]const u8, 0);

    // Find closing bracket
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return allocator.alloc([]const u8, 0);
    const inner = trimmed[1..close];

    var items: std.ArrayList([]const u8) = .{};
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }

    var rest = inner;
    while (rest.len > 0) {
        // Skip whitespace and commas
        rest = std.mem.trimLeft(u8, rest, &[_]u8{ ' ', '\t', ',', '\n', '\r' });
        if (rest.len == 0) break;

        if (rest[0] == '"') {
            // Find closing quote
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse break;
            try items.append(allocator, try allocator.dupe(u8, rest[1..end]));
            rest = rest[end + 1 ..];
        } else {
            // Bare value — take until comma or end
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            const val = std.mem.trim(u8, rest[0..end], &[_]u8{ ' ', '\t' });
            if (val.len > 0) {
                try items.append(allocator, try allocator.dupe(u8, val));
            }
            rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
        }
    }

    return items.toOwnedSlice(allocator);
}

/// Parse a TOML array that may span multiple lines.
/// `first_line` is the value part after `=` on the key line.
/// `lines` iterator is advanced to consume continuation lines until `]` is found.
/// Returns owned slice of owned strings.
fn parseTomlMultilineArray(
    allocator: std.mem.Allocator,
    first_line: []const u8,
    lines: *std.mem.SplitIterator(u8, .scalar),
) ![][]const u8 {
    const trimmed = std.mem.trim(u8, first_line, &[_]u8{ ' ', '\t' });

    // Check if it's a complete inline array
    if (trimmed.len >= 2 and trimmed[0] == '[') {
        if (std.mem.lastIndexOfScalar(u8, trimmed, ']') != null) {
            return parseTomlInlineArray(allocator, trimmed);
        }
    }

    // Multi-line: accumulate content until we find ]
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, trimmed);

    var found_close = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });
        if (line.len > 0 and line[0] == '#') continue; // skip comment lines
        try buf.appendSlice(allocator, " ");
        try buf.appendSlice(allocator, line);
        if (std.mem.indexOfScalar(u8, line, ']') != null) {
            found_close = true;
            break;
        }
    }

    // Unclosed bracket — reject rather than silently produce wrong results
    if (!found_close and std.mem.indexOfScalar(u8, buf.items, ']') == null) {
        return error.InvalidSyntax;
    }

    return parseTomlInlineArray(allocator, buf.items);
}

fn freeStringSlice(allocator: std.mem.Allocator, slice: [][]const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

// ─────────────────────────────────────────────────────────
// RoleDefinition
// ─────────────────────────────────────────────────────────

pub const RoleDefinition = struct {
    id: []const u8,
    name: []const u8,
    division: []const u8,
    emoji: []const u8,
    description: []const u8,
    write_patterns: [][]const u8,
    deny_write_patterns: [][]const u8,
    can_push: bool,
    can_merge: bool,
    trigger_events: [][]const u8,
    mission: []const u8,
    focus: []const u8,
    deliverables: [][]const u8,
    rules: [][]const u8,
    workflow: [][]const u8,
    success_metrics: [][]const u8,

    pub fn deinit(self: *RoleDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.division);
        allocator.free(self.emoji);
        allocator.free(self.description);
        freeStringSlice(allocator, self.write_patterns);
        freeStringSlice(allocator, self.deny_write_patterns);
        freeStringSlice(allocator, self.trigger_events);
        allocator.free(self.mission);
        allocator.free(self.focus);
        freeStringSlice(allocator, self.deliverables);
        freeStringSlice(allocator, self.rules);
        freeStringSlice(allocator, self.workflow);
        freeStringSlice(allocator, self.success_metrics);
    }
};

pub const RoleParseError = ParseError || std.fs.File.OpenError || std.fs.File.ReadError || error{StreamTooLong};

/// Parse a role TOML file into a RoleDefinition.
pub fn parseRoleDefinition(allocator: std.mem.Allocator, role_path: []const u8) RoleParseError!RoleDefinition {
    const file = try std.fs.cwd().openFile(role_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    return parseRoleContent(allocator, content);
}

/// Parse role TOML content string into a RoleDefinition.
pub fn parseRoleContent(allocator: std.mem.Allocator, content: []const u8) ParseError!RoleDefinition {
    var current_section: RoleSection = .none;

    // Scalar defaults
    var id: []const u8 = try allocator.dupe(u8, "");
    var name: []const u8 = try allocator.dupe(u8, "");
    var division: []const u8 = try allocator.dupe(u8, "");
    var emoji: []const u8 = try allocator.dupe(u8, "");
    var description: []const u8 = try allocator.dupe(u8, "");
    var mission: []const u8 = try allocator.dupe(u8, "");
    var focus: []const u8 = try allocator.dupe(u8, "");
    var can_push: bool = false;
    var can_merge: bool = false;

    // Array fields — null means not yet parsed
    var write_patterns: ?[][]const u8 = null;
    var deny_write_patterns: ?[][]const u8 = null;
    var trigger_events: ?[][]const u8 = null;
    var deliverables: ?[][]const u8 = null;
    var rules: ?[][]const u8 = null;
    var workflow: ?[][]const u8 = null;
    var success_metrics: ?[][]const u8 = null;

    errdefer {
        allocator.free(id);
        allocator.free(name);
        allocator.free(division);
        allocator.free(emoji);
        allocator.free(description);
        allocator.free(mission);
        allocator.free(focus);
        if (write_patterns) |p| freeStringSlice(allocator, p);
        if (deny_write_patterns) |p| freeStringSlice(allocator, p);
        if (trigger_events) |p| freeStringSlice(allocator, p);
        if (deliverables) |p| freeStringSlice(allocator, p);
        if (rules) |p| freeStringSlice(allocator, p);
        if (workflow) |p| freeStringSlice(allocator, p);
        if (success_metrics) |p| freeStringSlice(allocator, p);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });

        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Section header
        if (line[0] == '[' and (line.len < 2 or line[1] != '[')) {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section_name = std.mem.trim(u8, line[1..end], &[_]u8{ ' ', '\t' });
            if (std.mem.eql(u8, section_name, "identity")) {
                current_section = .identity;
            } else if (std.mem.eql(u8, section_name, "capabilities")) {
                current_section = .capabilities;
            } else if (std.mem.eql(u8, section_name, "triggers_on")) {
                current_section = .triggers_on;
            } else if (std.mem.eql(u8, section_name, "context")) {
                current_section = .context;
            } else {
                current_section = .none;
            }
            continue;
        }

        // Key = value
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], &[_]u8{ ' ', '\t' });
        const raw_val = std.mem.trim(u8, line[eq_idx + 1 ..], &[_]u8{ ' ', '\t' });

        switch (current_section) {
            .identity => {
                const val = stripValue(raw_val);
                if (std.mem.eql(u8, key, "id")) {
                    allocator.free(id);
                    id = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "name")) {
                    allocator.free(name);
                    name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "division")) {
                    allocator.free(division);
                    division = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "emoji")) {
                    allocator.free(emoji);
                    emoji = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "description")) {
                    allocator.free(description);
                    description = try allocator.dupe(u8, val);
                }
            },
            .capabilities => {
                if (std.mem.eql(u8, key, "read")) {
                    // read patterns — acknowledged but not stored in RoleDefinition
                    // (ownership.zig uses write/deny_write only)
                } else if (std.mem.eql(u8, key, "write")) {
                    if (write_patterns) |old| freeStringSlice(allocator, old);
                    write_patterns = try parseTomlMultilineArray(allocator, raw_val, &lines);
                } else if (std.mem.eql(u8, key, "deny_write")) {
                    if (deny_write_patterns) |old| freeStringSlice(allocator, old);
                    deny_write_patterns = try parseTomlMultilineArray(allocator, raw_val, &lines);
                } else if (std.mem.eql(u8, key, "can_push")) {
                    can_push = parseTomlBool(stripValue(raw_val)) orelse blk: {
                        std.log.warn("[teammux] role: invalid boolean for can_push: '{s}', defaulting to false", .{stripValue(raw_val)});
                        break :blk false;
                    };
                } else if (std.mem.eql(u8, key, "can_merge")) {
                    can_merge = parseTomlBool(stripValue(raw_val)) orelse blk: {
                        std.log.warn("[teammux] role: invalid boolean for can_merge: '{s}', defaulting to false", .{stripValue(raw_val)});
                        break :blk false;
                    };
                }
            },
            .triggers_on => {
                if (std.mem.eql(u8, key, "events")) {
                    if (trigger_events) |old| freeStringSlice(allocator, old);
                    trigger_events = try parseTomlMultilineArray(allocator, raw_val, &lines);
                }
            },
            .context => {
                if (std.mem.eql(u8, key, "mission")) {
                    allocator.free(mission);
                    mission = try allocator.dupe(u8, stripValue(raw_val));
                } else if (std.mem.eql(u8, key, "focus")) {
                    allocator.free(focus);
                    focus = try allocator.dupe(u8, stripValue(raw_val));
                } else if (std.mem.eql(u8, key, "deliverables")) {
                    if (deliverables) |old| freeStringSlice(allocator, old);
                    deliverables = try parseTomlMultilineArray(allocator, raw_val, &lines);
                } else if (std.mem.eql(u8, key, "rules")) {
                    if (rules) |old| freeStringSlice(allocator, old);
                    rules = try parseTomlMultilineArray(allocator, raw_val, &lines);
                } else if (std.mem.eql(u8, key, "workflow")) {
                    if (workflow) |old| freeStringSlice(allocator, old);
                    workflow = try parseTomlMultilineArray(allocator, raw_val, &lines);
                } else if (std.mem.eql(u8, key, "success_metrics")) {
                    if (success_metrics) |old| freeStringSlice(allocator, old);
                    success_metrics = try parseTomlMultilineArray(allocator, raw_val, &lines);
                }
            },
            .none => {},
        }
    }

    // Validate required fields
    if (id.len == 0) {
        std.log.warn("[teammux] role file has no identity.id field", .{});
        return error.InvalidSyntax;
    }

    return RoleDefinition{
        .id = id,
        .name = name,
        .division = division,
        .emoji = emoji,
        .description = description,
        .write_patterns = write_patterns orelse try allocator.alloc([]const u8, 0),
        .deny_write_patterns = deny_write_patterns orelse try allocator.alloc([]const u8, 0),
        .can_push = can_push,
        .can_merge = can_merge,
        .trigger_events = trigger_events orelse try allocator.alloc([]const u8, 0),
        .mission = mission,
        .focus = focus,
        .deliverables = deliverables orelse try allocator.alloc([]const u8, 0),
        .rules = rules orelse try allocator.alloc([]const u8, 0),
        .workflow = workflow orelse try allocator.alloc([]const u8, 0),
        .success_metrics = success_metrics orelse try allocator.alloc([]const u8, 0),
    };
}

// ─────────────────────────────────────────────────────────
// Role path resolution
// ─────────────────────────────────────────────────────────

/// Resolve a role ID to its TOML file path.
/// Search order (first match wins):
///   1. {project_root}/.teammux/roles/{role_id}.toml — project-local overrides
///   2. ~/.teammux/roles/{role_id}.toml — user-level custom roles
///   3. {exe_dir}/../Resources/roles/{role_id}.toml — app bundle
///   4. {exe_dir}/roles/{role_id}.toml — dev build fallback
/// Returns null if not found in any location. Caller must free the returned path.
pub fn resolveRolePath(
    allocator: std.mem.Allocator,
    role_id: []const u8,
    project_root: []const u8,
) !?[]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.toml", .{role_id});
    defer allocator.free(filename);

    // 1. Project-local: {project_root}/.teammux/roles/{role_id}.toml
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/.teammux/roles/{s}", .{ project_root, filename });
        if (fileExists(path)) return path;
        allocator.free(path);
    }

    // 2. User-level: ~/.teammux/roles/{role_id}.toml
    if (std.posix.getenv("HOME")) |home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/.teammux/roles/{s}", .{ home, filename });
        if (fileExists(path)) return path;
        allocator.free(path);
    }

    // Only exercised in app bundle — tests use temp dirs
    // 3. App bundle: {exe_dir}/../Resources/roles/{role_id}.toml
    // 4. Dev build: {exe_dir}/roles/{role_id}.toml
    if (getExeDir(allocator)) |exe_dir| {
        defer allocator.free(exe_dir);
        {
            const path = try std.fmt.allocPrint(allocator, "{s}/../Resources/roles/{s}", .{ exe_dir, filename });
            if (fileExists(path)) return path;
            allocator.free(path);
        }
        {
            const path = try std.fmt.allocPrint(allocator, "{s}/roles/{s}", .{ exe_dir, filename });
            if (fileExists(path)) return path;
            allocator.free(path);
        }
    }

    return null;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

pub fn getExeDir(allocator: std.mem.Allocator) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&buf) catch return null;
    const dir = std.fs.path.dirname(exe_path) orelse return null;
    return allocator.dupe(u8, dir) catch null;
}

/// List all available role IDs from a directory. Returns owned slice of owned strings.
pub fn listRolesInDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return allocator.alloc([]const u8, 0);
    defer dir.close();

    var items: std.ArrayList([]const u8) = .{};
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        // Strip .toml suffix to get role ID
        const role_id = entry.name[0 .. entry.name.len - 5];
        try items.append(allocator, try allocator.dupe(u8, role_id));
    }

    return items.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────
// File loading
// ─────────────────────────────────────────────────────────

pub const LoadError = ParseError || std.fs.File.OpenError || std.fs.File.ReadError || error{StreamTooLong};

/// Load config from a file path.
pub fn load(allocator: std.mem.Allocator, path: []const u8) LoadError!Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    return parse(allocator, content);
}

/// Load config from base path with optional local override file.
pub fn loadWithOverrides(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    override_path: ?[]const u8,
) LoadError!Config {
    var cfg = try load(allocator, base_path);
    errdefer cfg.deinit(allocator);

    if (override_path) |op| {
        const override_file = std.fs.cwd().openFile(op, .{}) catch |err| switch (err) {
            error.FileNotFound => return cfg,
            else => return err,
        };
        defer override_file.close();
        const override_content = try override_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(override_content);

        var override_cfg = try parse(allocator, override_content);
        defer override_cfg.deinit(allocator);

        // Merge: override values replace base values where explicitly set
        // Uses fields_set tracking (not default-value comparison) so overriding
        // back to the default value works correctly.
        if (override_cfg.fields_set.github_token) {
            if (cfg.github_token) |old| allocator.free(old);
            cfg.github_token = if (override_cfg.github_token) |t| try allocator.dupe(u8, t) else null;
        }
        if (override_cfg.fields_set.tl_model) {
            allocator.free(cfg.team_lead.model);
            cfg.team_lead.model = try allocator.dupe(u8, override_cfg.team_lead.model);
        }
        if (override_cfg.fields_set.tl_permissions) {
            allocator.free(cfg.team_lead.permissions);
            cfg.team_lead.permissions = try allocator.dupe(u8, override_cfg.team_lead.permissions);
        }
    }
    return cfg;
}

// ─────────────────────────────────────────────────────────
// Dot-key lookup
// ─────────────────────────────────────────────────────────

/// Get a config value by dot-notation key.
/// Returns null if key not found.
pub fn get(cfg: *const Config, dot_key: []const u8) ?[]const u8 {
    // project.*
    if (std.mem.eql(u8, dot_key, "project.name")) return cfg.project.name;
    if (std.mem.eql(u8, dot_key, "project.github_repo")) return cfg.project.github_repo;

    // team_lead.*
    if (std.mem.eql(u8, dot_key, "team_lead.model")) return cfg.team_lead.model;
    if (std.mem.eql(u8, dot_key, "team_lead.permissions")) return cfg.team_lead.permissions;

    // github.*
    if (std.mem.eql(u8, dot_key, "github.token")) return cfg.github_token;

    // bus.*
    if (std.mem.eql(u8, dot_key, "bus.delivery")) return cfg.bus_delivery;

    return null;
}

// ─────────────────────────────────────────────────────────
// Config Watcher (kqueue-based hot-reload)
// ─────────────────────────────────────────────────────────

pub const ConfigWatcher = struct {
    allocator: std.mem.Allocator,
    config_path: []const u8,
    kq: i32,
    watch_fd: std.posix.fd_t,
    callback: ?*const fn (?*anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8) !ConfigWatcher {
        return ConfigWatcher{
            .allocator = allocator,
            .config_path = config_path,
            .kq = -1,
            .watch_fd = -1,
            .callback = null,
            .userdata = null,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(
        self: *ConfigWatcher,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) !void {
        self.callback = callback;
        self.userdata = userdata;

        // Open the config file for watching
        const file = try std.fs.cwd().openFile(self.config_path, .{});
        self.watch_fd = file.handle;
        // Intentionally NOT closing file — we keep the fd for kqueue

        self.kq = try std.posix.kqueue();
        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    pub fn stop(self: *ConfigWatcher) void {
        self.running.store(false, .release);
        // Let the thread exit via its 1-second kevent timeout
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *ConfigWatcher) void {
        self.stop();
        if (self.kq >= 0) {
            std.posix.close(@intCast(self.kq));
            self.kq = -1;
        }
        if (self.watch_fd >= 0) {
            std.posix.close(@intCast(self.watch_fd));
            self.watch_fd = -1;
        }
    }

    fn watchLoop(self: *ConfigWatcher) void {
        while (self.running.load(.acquire)) {
            // Register for VNODE events
            const changelist = [1]std.posix.Kevent{.{
                .ident = @intCast(self.watch_fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.ATTRIB,
                .data = 0,
                .udata = 0,
            }};

            var eventlist: [1]std.posix.Kevent = undefined;

            // 1-second timeout so we can check the running flag
            const timeout = std.posix.timespec{ .sec = 1, .nsec = 0 };

            const n = std.posix.kevent(
                self.kq,
                &changelist,
                &eventlist,
                &timeout,
            ) catch {
                // kqueue was closed or error — exit loop
                break;
            };

            if (n > 0) {
                const fflags = eventlist[0].fflags;

                // Handle rename/delete: editor saved via temp file rename
                if (fflags & std.c.NOTE.DELETE != 0 or fflags & std.c.NOTE.RENAME != 0) {
                    // Close old fd and mark invalid to prevent stale kqueue registration
                    std.posix.close(@intCast(self.watch_fd));
                    self.watch_fd = -1;
                    // Small delay for rename to complete
                    std.Thread.sleep(100 * std.time.ns_per_ms);

                    const new_file = std.fs.cwd().openFile(self.config_path, .{}) catch {
                        // File not available yet — retry next iteration with watch_fd = -1
                        // The changelist will use -1 which kevent will reject; caught by catch break above.
                        continue;
                    };
                    self.watch_fd = new_file.handle;
                }

                // Fire callback
                if (self.callback) |cb| {
                    cb(self.userdata);
                }
            }
        }
    }
};

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "config - parse minimal toml" {
    const toml =
        \\[project]
        \\name = "my-project"
        \\
        \\[team_lead]
        \\agent = "claude-code"
        \\model = "claude-opus-4-6"
        \\permissions = "full"
        \\
        \\[bus]
        \\delivery = "guaranteed"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my-project", cfg.project.name);
    try std.testing.expect(cfg.project.github_repo == null);
    try std.testing.expect(cfg.team_lead.agent == .claude_code);
    try std.testing.expectEqualStrings("claude-opus-4-6", cfg.team_lead.model);
    try std.testing.expectEqualStrings("full", cfg.team_lead.permissions);
    try std.testing.expectEqualStrings("guaranteed", cfg.bus_delivery);
    try std.testing.expect(cfg.workers.len == 0);
}

test "config - parse with workers" {
    const toml =
        \\[project]
        \\name = "test-project"
        \\github_repo = "owner/repo"
        \\
        \\[team_lead]
        \\agent = "claude-code"
        \\model = "claude-opus-4-6"
        \\permissions = "full"
        \\
        \\[[workers]]
        \\id = "worker-1"
        \\name = "Frontend"
        \\agent = "claude-code"
        \\model = "claude-sonnet-4-6"
        \\permissions = "full"
        \\default_task = ""
        \\
        \\[[workers]]
        \\id = "worker-2"
        \\name = "Backend"
        \\agent = "codex-cli"
        \\model = "gpt-5"
        \\permissions = "full"
        \\
        \\[bus]
        \\delivery = "guaranteed"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test-project", cfg.project.name);
    try std.testing.expectEqualStrings("owner/repo", cfg.project.github_repo.?);
    try std.testing.expect(cfg.workers.len == 2);
    try std.testing.expectEqualStrings("worker-1", cfg.workers[0].id);
    try std.testing.expectEqualStrings("Frontend", cfg.workers[0].name);
    try std.testing.expect(cfg.workers[0].agent == .claude_code);
    try std.testing.expectEqualStrings("worker-2", cfg.workers[1].id);
    try std.testing.expectEqualStrings("Backend", cfg.workers[1].name);
    try std.testing.expect(cfg.workers[1].agent == .codex_cli);
    try std.testing.expectEqualStrings("gpt-5", cfg.workers[1].model);
}

test "config - missing optional fields use defaults" {
    const toml =
        \\[project]
        \\name = "bare-minimum"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("bare-minimum", cfg.project.name);
    try std.testing.expect(cfg.project.github_repo == null);
    try std.testing.expect(cfg.team_lead.agent == .claude_code);
    try std.testing.expectEqualStrings("claude-opus-4-6", cfg.team_lead.model);
    try std.testing.expectEqualStrings("guaranteed", cfg.bus_delivery);
    try std.testing.expect(cfg.github_token == null);
    try std.testing.expect(cfg.workers.len == 0);
}

test "config - comments and blank lines ignored" {
    const toml =
        \\# This is a comment
        \\
        \\[project]
        \\# Another comment
        \\name = "commented"  # inline comment
        \\
        \\[bus]
        \\delivery = "guaranteed"  # trailing comment
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("commented", cfg.project.name);
    try std.testing.expectEqualStrings("guaranteed", cfg.bus_delivery);
}

test "config - dot-key lookup" {
    const toml =
        \\[project]
        \\name = "lookup-test"
        \\github_repo = "org/repo"
        \\
        \\[team_lead]
        \\model = "claude-opus-4-6"
        \\permissions = "restricted"
        \\
        \\[bus]
        \\delivery = "observer"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("lookup-test", get(&cfg, "project.name").?);
    try std.testing.expectEqualStrings("org/repo", get(&cfg, "project.github_repo").?);
    try std.testing.expectEqualStrings("claude-opus-4-6", get(&cfg, "team_lead.model").?);
    try std.testing.expectEqualStrings("restricted", get(&cfg, "team_lead.permissions").?);
    try std.testing.expectEqualStrings("observer", get(&cfg, "bus.delivery").?);
    try std.testing.expect(get(&cfg, "nonexistent.key") == null);
}

test "config - github token in config" {
    const toml =
        \\[github]
        \\token = "ghp_test123"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ghp_test123", cfg.github_token.?);
    try std.testing.expectEqualStrings("ghp_test123", get(&cfg, "github.token").?);
}

test "config - load from file" {
    // Write a temp config file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const config_content =
        \\[project]
        \\name = "file-test"
        \\
        \\[team_lead]
        \\agent = "claude-code"
        \\model = "claude-opus-4-6"
        \\permissions = "full"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.toml", .data = config_content });

    // Get absolute path
    const abs_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.toml");
    defer std.testing.allocator.free(abs_path);

    var cfg = try load(std.testing.allocator, abs_path);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("file-test", cfg.project.name);
}

test "config - local override merges correctly" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const base =
        \\[project]
        \\name = "override-test"
        \\
        \\[team_lead]
        \\agent = "claude-code"
        \\model = "claude-opus-4-6"
        \\permissions = "full"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.toml", .data = base });

    const override =
        \\[github]
        \\token = "ghp_override_token"
        \\
        \\[team_lead]
        \\model = "claude-sonnet-4-6"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.local.toml", .data = override });

    const base_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.toml");
    defer std.testing.allocator.free(base_path);
    const override_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.local.toml");
    defer std.testing.allocator.free(override_path);

    var cfg = try loadWithOverrides(std.testing.allocator, base_path, override_path);
    defer cfg.deinit(std.testing.allocator);

    // Base values preserved
    try std.testing.expectEqualStrings("override-test", cfg.project.name);
    // Override values applied
    try std.testing.expectEqualStrings("ghp_override_token", cfg.github_token.?);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", cfg.team_lead.model);
    // Non-overridden values kept from base
    try std.testing.expectEqualStrings("full", cfg.team_lead.permissions);
}

test "config - override back to default value works" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Base config has non-default model
    const base =
        \\[project]
        \\name = "default-override"
        \\
        \\[team_lead]
        \\model = "gpt-5"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.toml", .data = base });

    // Override sets model back to the default value
    const override =
        \\[team_lead]
        \\model = "claude-opus-4-6"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.local.toml", .data = override });

    const base_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.toml");
    defer std.testing.allocator.free(base_path);
    const override_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.local.toml");
    defer std.testing.allocator.free(override_path);

    var cfg = try loadWithOverrides(std.testing.allocator, base_path, override_path);
    defer cfg.deinit(std.testing.allocator);

    // Override to default value must be applied (not ignored)
    try std.testing.expectEqualStrings("claude-opus-4-6", cfg.team_lead.model);
}

test "config - load with missing override file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const base =
        \\[project]
        \\name = "no-override"
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "config.toml", .data = base });

    const base_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "config.toml");
    defer std.testing.allocator.free(base_path);

    var cfg = try loadWithOverrides(std.testing.allocator, base_path, "/nonexistent/config.local.toml");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("no-override", cfg.project.name);
}

// ─── TOML helper tests ───────────────────────────────────

test "parseTomlBool - true and false" {
    try std.testing.expect(parseTomlBool("true").? == true);
    try std.testing.expect(parseTomlBool("false").? == false);
    try std.testing.expect(parseTomlBool(" true ").? == true);
    try std.testing.expect(parseTomlBool("yes") == null);
    try std.testing.expect(parseTomlBool("") == null);
}

test "parseTomlInlineArray - basic" {
    const alloc = std.testing.allocator;
    const result = try parseTomlInlineArray(alloc, "[\"src/**\", \"tests/**\"]");
    defer {
        for (result) |s| alloc.free(s);
        alloc.free(result);
    }
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqualStrings("src/**", result[0]);
    try std.testing.expectEqualStrings("tests/**", result[1]);
}

test "parseTomlInlineArray - empty" {
    const alloc = std.testing.allocator;
    const result = try parseTomlInlineArray(alloc, "[]");
    defer alloc.free(result);
    try std.testing.expect(result.len == 0);
}

test "parseTomlInlineArray - single element" {
    const alloc = std.testing.allocator;
    const result = try parseTomlInlineArray(alloc, "[\"only\"]");
    defer {
        for (result) |s| alloc.free(s);
        alloc.free(result);
    }
    try std.testing.expect(result.len == 1);
    try std.testing.expectEqualStrings("only", result[0]);
}

test "parseTomlMultilineArray - inline completes on one line" {
    const alloc = std.testing.allocator;
    const input = "[\"a\", \"b\"]";
    var lines = std.mem.splitScalar(u8, "", '\n');
    const result = try parseTomlMultilineArray(alloc, input, &lines);
    defer {
        for (result) |s| alloc.free(s);
        alloc.free(result);
    }
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
}

test "parseTomlMultilineArray - spans multiple lines" {
    const alloc = std.testing.allocator;
    const continuation =
        \\  "item1",
        \\  "item2",
        \\  "item3"
        \\]
    ;
    var lines = std.mem.splitScalar(u8, continuation, '\n');
    const result = try parseTomlMultilineArray(alloc, "[", &lines);
    defer {
        for (result) |s| alloc.free(s);
        alloc.free(result);
    }
    try std.testing.expect(result.len == 3);
    try std.testing.expectEqualStrings("item1", result[0]);
    try std.testing.expectEqualStrings("item2", result[1]);
    try std.testing.expectEqualStrings("item3", result[2]);
}

// ─── RoleDefinition tests ────────────────────────────────

test "parseRoleContent - full role TOML" {
    const alloc = std.testing.allocator;
    const toml =
        \\[identity]
        \\id = "frontend-engineer"
        \\name = "Frontend Engineer"
        \\division = "engineering"
        \\emoji = "paint"
        \\description = "React, Vue, UI implementation"
        \\
        \\[capabilities]
        \\read = ["**"]
        \\write = ["src/frontend/**", "tests/frontend/**"]
        \\deny_write = ["src/backend/**", "infrastructure/**"]
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "Build pixel-perfect UI components"
        \\focus = "Component architecture, accessibility"
        \\deliverables = ["Working components", "Tests"]
        \\rules = ["Never modify backend", "Write tests"]
        \\workflow = ["Read task", "Implement", "Test"]
        \\success_metrics = ["Tests pass", "No regressions"]
    ;

    var role = try parseRoleContent(alloc, toml);
    defer role.deinit(alloc);

    try std.testing.expectEqualStrings("frontend-engineer", role.id);
    try std.testing.expectEqualStrings("Frontend Engineer", role.name);
    try std.testing.expectEqualStrings("engineering", role.division);
    try std.testing.expectEqualStrings("paint", role.emoji);
    try std.testing.expectEqualStrings("React, Vue, UI implementation", role.description);

    try std.testing.expect(role.write_patterns.len == 2);
    try std.testing.expectEqualStrings("src/frontend/**", role.write_patterns[0]);
    try std.testing.expectEqualStrings("tests/frontend/**", role.write_patterns[1]);

    try std.testing.expect(role.deny_write_patterns.len == 2);
    try std.testing.expectEqualStrings("src/backend/**", role.deny_write_patterns[0]);
    try std.testing.expectEqualStrings("infrastructure/**", role.deny_write_patterns[1]);

    try std.testing.expect(role.can_push == false);
    try std.testing.expect(role.can_merge == false);

    try std.testing.expect(role.trigger_events.len == 0);

    try std.testing.expectEqualStrings("Build pixel-perfect UI components", role.mission);
    try std.testing.expectEqualStrings("Component architecture, accessibility", role.focus);

    try std.testing.expect(role.deliverables.len == 2);
    try std.testing.expect(role.rules.len == 2);
    try std.testing.expect(role.workflow.len == 3);
    try std.testing.expect(role.success_metrics.len == 2);
}

test "parseRoleContent - multiline arrays" {
    const alloc = std.testing.allocator;
    const toml =
        \\[identity]
        \\id = "test-role"
        \\name = "Test"
        \\division = "testing"
        \\emoji = "x"
        \\description = "test"
        \\
        \\[capabilities]
        \\write = [
        \\  "src/a/**",
        \\  "src/b/**"
        \\]
        \\deny_write = []
        \\can_push = true
        \\can_merge = true
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;

    var role = try parseRoleContent(alloc, toml);
    defer role.deinit(alloc);

    try std.testing.expect(role.write_patterns.len == 2);
    try std.testing.expectEqualStrings("src/a/**", role.write_patterns[0]);
    try std.testing.expectEqualStrings("src/b/**", role.write_patterns[1]);
    try std.testing.expect(role.can_push == true);
    try std.testing.expect(role.can_merge == true);
}

test "parseRoleContent - empty content returns InvalidSyntax (missing id)" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidSyntax, parseRoleContent(alloc, ""));
}

test "parseTomlMultilineArray - unclosed bracket returns InvalidSyntax" {
    const alloc = std.testing.allocator;
    // No closing ] anywhere in the continuation lines
    const continuation =
        \\  "item1",
        \\  "item2"
    ;
    var lines = std.mem.splitScalar(u8, continuation, '\n');
    try std.testing.expectError(error.InvalidSyntax, parseTomlMultilineArray(alloc, "[", &lines));
}

test "parseRoleDefinition - reads from file" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const role_toml =
        \\[identity]
        \\id = "file-role"
        \\name = "File Role"
        \\division = "testing"
        \\emoji = "f"
        \\description = "from file"
        \\
        \\[capabilities]
        \\write = ["src/**"]
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "test-role.toml", .data = role_toml });

    const abs_path = try tmp_dir.dir.realpathAlloc(alloc, "test-role.toml");
    defer alloc.free(abs_path);

    var role = try parseRoleDefinition(alloc, abs_path);
    defer role.deinit(alloc);

    try std.testing.expectEqualStrings("file-role", role.id);
    try std.testing.expectEqualStrings("from file", role.description);
    try std.testing.expect(role.write_patterns.len == 1);
    try std.testing.expectEqualStrings("src/**", role.write_patterns[0]);
}

// ─── resolveRolePath tests ───────────────────────────────

test "resolveRolePath - finds project-local role" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    // Create project-local roles directory
    try tmp_dir.dir.makePath(".teammux/roles");
    try tmp_dir.dir.writeFile(.{ .sub_path = ".teammux/roles/test-role.toml", .data = "[identity]\nid = \"test-role\"\n" });

    const result = try resolveRolePath(alloc, "test-role", project_root);
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    try std.testing.expect(std.mem.endsWith(u8, result.?, ".teammux/roles/test-role.toml"));
}

test "resolveRolePath - returns null for missing role" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    const result = try resolveRolePath(alloc, "nonexistent-role", project_root);
    try std.testing.expect(result == null);
}

test "resolveRolePath - project-local takes precedence" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const project_root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    // Create project-local role
    try tmp_dir.dir.makePath(".teammux/roles");
    try tmp_dir.dir.writeFile(.{ .sub_path = ".teammux/roles/priority-role.toml", .data = "[identity]\nid = \"priority-role\"\n" });

    const result = try resolveRolePath(alloc, "priority-role", project_root);
    try std.testing.expect(result != null);
    defer alloc.free(result.?);
    // Should contain project root path, not home dir
    try std.testing.expect(std.mem.indexOf(u8, result.?, project_root) != null);
}

test "listRolesInDir - lists TOML files" {
    const alloc = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "frontend-engineer.toml", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "backend-engineer.toml", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "README.md", .data = "" }); // should be ignored

    const dir_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const roles = try listRolesInDir(alloc, dir_path);
    defer {
        for (roles) |r| alloc.free(r);
        alloc.free(roles);
    }

    try std.testing.expect(roles.len == 2);
    // Check both names are present (order not guaranteed)
    var found_fe = false;
    var found_be = false;
    for (roles) |r| {
        if (std.mem.eql(u8, r, "frontend-engineer")) found_fe = true;
        if (std.mem.eql(u8, r, "backend-engineer")) found_be = true;
    }
    try std.testing.expect(found_fe);
    try std.testing.expect(found_be);
}

test "listRolesInDir - empty on missing directory" {
    const alloc = std.testing.allocator;
    const roles = try listRolesInDir(alloc, "/nonexistent/path/roles");
    defer alloc.free(roles);
    try std.testing.expect(roles.len == 0);
}

// ─── WorkerConfig role field tests ───────────────────────

test "config - worker role field parsed" {
    const toml =
        \\[project]
        \\name = "role-test"
        \\
        \\[[workers]]
        \\id = "w1"
        \\name = "Frontend"
        \\agent = "claude-code"
        \\model = "claude-sonnet-4-6"
        \\permissions = "full"
        \\role = "frontend-engineer"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.workers.len == 1);
    try std.testing.expectEqualStrings("frontend-engineer", cfg.workers[0].role.?);
    try std.testing.expect(cfg.workers[0].role_path == null);
}

test "config - worker without role has null" {
    const toml =
        \\[project]
        \\name = "no-role"
        \\
        \\[[workers]]
        \\id = "w1"
        \\name = "Generic"
        \\agent = "claude-code"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.workers.len == 1);
    try std.testing.expect(cfg.workers[0].role == null);
    try std.testing.expect(cfg.workers[0].role_path == null);
}

test "config - multiple workers with and without roles" {
    const toml =
        \\[project]
        \\name = "mixed"
        \\
        \\[[workers]]
        \\id = "w1"
        \\name = "Frontend"
        \\role = "frontend-engineer"
        \\
        \\[[workers]]
        \\id = "w2"
        \\name = "Generic"
    ;

    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.workers.len == 2);
    try std.testing.expectEqualStrings("frontend-engineer", cfg.workers[0].role.?);
    try std.testing.expect(cfg.workers[1].role == null);
}
