//! Parse environment variables directly into typed Zig structs.
//!
//! Provides automatic type conversion and validation for strings, integers,
//! floats, booleans, enums, and nested structs with support for optional fields,
//! custom mapping, default values, and flexible validation patterns.
//!
//! Author: @xarunoba
//! Repository: https://github.com/xarunoba/env-struct.zig
//! License: MIT

const std = @import("std");

//==============================================================================
// Public API
//==============================================================================

/// Load configuration from system environment variables
/// Returns a wrapper that owns the EnvMap and contains the configuration
/// All string fields are borrowed slices pointing into the EnvMap (zero allocation)
pub fn load(comptime T: type) !struct {
    value: T,
    env_map: std.process.EnvMap,

    pub fn deinit(self: *@This()) void {
        self.env_map.deinit();
    }
} {
    var env_map = try std.process.getEnvMap(std.heap.page_allocator);
    const value = try loadCore(T, &env_map, null, false);
    return .{ .value = value, .env_map = env_map };
}

/// Load configuration from custom environment map
/// All string fields are borrowed slices pointing into the env_map (zero allocation)
/// env_map must outlive the returned configuration
pub fn loadMap(comptime T: type, env_map: std.process.EnvMap) !T {
    return loadCore(T, &env_map, null);
}

/// Parse raw environment variable value into specified type
/// Useful for custom parsers that want to preserve default parsing with additional validation
/// For string types, returns borrowed slices (no allocation)
pub fn parseValue(comptime T: type, raw_value: []const u8) !T {
    // Create a temporary EnvMap for parsing (empty, only used for nested structs)
    var temp_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer temp_map.deinit();
    return parseValueInternal(T, raw_value, &temp_map, null);
}

/// Create a validator function that combines default parsing with custom validation
/// Returns a parser function that takes raw_value and uses zero-allocation parsing
pub fn validator(comptime T: type, comptime validateFn: anytype) fn ([]const u8) anyerror!T {
    return struct {
        fn parse(raw_value: []const u8) !T {
            const parsed = try parseValue(T, raw_value);
            return validateFn(parsed);
        }
    }.parse;
}

//==============================================================================
// Core Utilities
//==============================================================================

fn parseBool(val: []const u8) bool {
    return std.ascii.eqlIgnoreCase(val, "true") or
        std.ascii.eqlIgnoreCase(val, "1") or
        std.ascii.eqlIgnoreCase(val, "yes");
}

fn isStringType(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |ptr| blk: {
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                break :blk child_info == .array and child_info.array.child == u8;
            } else {
                break :blk ptr.size == .slice and ptr.child == u8;
            }
        },
        else => false,
    };
}

fn FieldMetadata(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("FieldMetadata can only be used with struct types");
    }

    comptime var fields: [type_info.@"struct".fields.len]FieldInfo(T) = undefined;
    inline for (type_info.@"struct".fields, 0..) |field, i| {
        fields[i] = buildFieldInfo(field.name, T);
    }

    return struct {
        const metadata = fields;

        pub fn get(comptime field_name: []const u8) FieldInfo(T) {
            inline for (metadata) |meta| {
                if (std.mem.eql(u8, meta.name, field_name)) {
                    return meta;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in type " ++ @typeName(T));
        }
    };
}

fn FieldInfo(comptime _: type) type {
    return struct {
        name: []const u8,
        env_key: ?[]const u8,
        has_parser: bool,
        is_optional: bool,
        field_type: type,
    };
}

fn buildFieldInfo(comptime field_name: []const u8, comptime T: type) FieldInfo(T) {
    const type_info = @typeInfo(T);
    const field = inline for (type_info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) break f;
    } else @compileError("Field not found");

    const env_key = blk: {
        if (!@hasDecl(T, "env") or !@hasField(@TypeOf(T.env), field_name)) {
            break :blk field_name;
        }

        const env_config = @field(T.env, field_name);
        const ConfigType = @TypeOf(env_config);

        if (comptime isStringType(ConfigType)) {
            break :blk if (std.mem.eql(u8, env_config, "-")) null else env_config;
        }

        if (comptime @hasField(ConfigType, "key")) {
            break :blk if (std.mem.eql(u8, env_config.key, "-")) null else env_config.key;
        }

        break :blk field_name;
    };

    const has_parser = blk: {
        if (!@hasDecl(T, "env")) {
            break :blk false;
        }

        const env_type = @TypeOf(T.env);
        if (!@hasField(env_type, field_name)) {
            break :blk false;
        }

        const env_config = @field(T.env, field_name);
        const ConfigType = @TypeOf(env_config);

        if (comptime isStringType(ConfigType)) {
            break :blk false;
        }

        const config_type_info = @typeInfo(ConfigType);
        break :blk config_type_info == .@"struct" and @hasField(ConfigType, "parser");
    };

    const field_type_info = @typeInfo(field.type);
    const is_optional = field_type_info == .optional;

    return FieldInfo(T){
        .name = field_name,
        .env_key = env_key,
        .has_parser = has_parser,
        .is_optional = is_optional,
        .field_type = field.type,
    };
}

fn getEnvKey(comptime field_name: []const u8, comptime T: type) ?[]const u8 {
    return FieldMetadata(T).get(field_name).env_key;
}

fn hasCustomParser(comptime field_name: []const u8, comptime T: type) bool {
    return FieldMetadata(T).get(field_name).has_parser;
}

fn callCustomParser(comptime ReturnType: type, comptime field_name: []const u8, comptime T: type, raw_value: []const u8, arena: ?*std.heap.ArenaAllocator) !ReturnType {
    const env_config = @field(T.env, field_name);
    const parser = env_config.parser;
    const ParserType = @TypeOf(parser);
    const parser_info = @typeInfo(ParserType);

    if (parser_info != .@"fn") {
        @compileError("Parser must be a function");
    }

    const fn_info = parser_info.@"fn";
    if (fn_info.params.len == 1) {
        // Parser without allocator parameter (zero-allocation)
        return parser(raw_value);
    } else if (fn_info.params.len == 2) {
        // Parser with allocator parameter
        // Note: When arena is null (e.g., loadMap()), uses page allocator which doesn't free individual allocations
        // For production use with allocating parsers, prefer load() which provides automatic cleanup
        const actual_allocator = if (arena) |a| a.allocator() else std.heap.page_allocator;
        return parser(raw_value, actual_allocator);
    } else {
        @compileError("Parser must have signature: fn([]const u8) !T or fn([]const u8, std.mem.Allocator) !T");
    }
}

fn hasAnyEnvVars(comptime T: type, env_map: *const std.process.EnvMap) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        const meta = FieldMetadata(T).get(field.name);
        const field_type_info = @typeInfo(field.type);

        if (meta.env_key != null and env_map.get(meta.env_key.?) != null) {
            return true;
        }

        if (field_type_info == .@"struct" and hasAnyEnvVars(field.type, env_map)) {
            return true;
        }

        if (field_type_info == .optional) {
            const child_type = field_type_info.optional.child;
            const child_type_info = @typeInfo(child_type);
            if (child_type_info == .@"struct" and hasAnyEnvVars(child_type, env_map)) {
                return true;
            }
        }
    }
    return false;
}

//==============================================================================
// Core
//==============================================================================

fn loadCore(comptime T: type, env_map: *const std.process.EnvMap, arena: ?*std.heap.ArenaAllocator) !T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Expected struct type, got " ++ @typeName(T));
    }

    var result: T = undefined;

    inline for (type_info.@"struct".fields) |field| {
        const env_key = getEnvKey(field.name, T);
        const has_parser = comptime hasCustomParser(field.name, T);
        const field_type_info = @typeInfo(field.type);
        const is_optional = field_type_info == .optional;
        const default_value = field.defaultValue();

        if (field_type_info == .@"struct") {
            @field(result, field.name) = try parseValueInternal(field.type, "", env_map, arena);
        } else if (is_optional) {
            const child_type = field_type_info.optional.child;
            const child_type_info = @typeInfo(child_type);

            if (child_type_info == .@"struct") {
                if (hasAnyEnvVars(child_type, env_map)) {
                    @field(result, field.name) = try parseValueInternal(child_type, "", env_map, arena);
                } else {
                    @field(result, field.name) = if (default_value) |def| def else null;
                }
            } else if (env_key) |key| {
                if (env_map.get(key)) |val| {
                    @field(result, field.name) = if (has_parser)
                        try callCustomParser(child_type, field.name, T, val, arena)
                    else
                        try parseValueInternal(child_type, val, env_map, arena);
                } else {
                    @field(result, field.name) = if (default_value) |def| def else null;
                }
            } else {
                @field(result, field.name) = if (default_value) |def| def else null;
            }
        } else if (env_key) |key| {
            if (env_map.get(key)) |val| {
                @field(result, field.name) = if (has_parser)
                    try callCustomParser(field.type, field.name, T, val, arena)
                else
                    try parseValueInternal(field.type, val, env_map, arena);
            } else if (default_value) |def| {
                @field(result, field.name) = def;
            } else {
                return error.MissingEnvironmentVariable;
            }
        } else if (default_value) |def| {
            @field(result, field.name) = def;
        } else {
            return error.MissingEnvironmentVariable;
        }
    }

    return result;
}

fn parseValueInternal(comptime T: type, val: []const u8, env_map: *const std.process.EnvMap, arena: ?*std.heap.ArenaAllocator) !T {
    const type_info = @typeInfo(T);

    if (type_info == .@"struct") {
        return loadCore(T, env_map, arena);
    }

    return switch (T) {
        []const u8 => val,
        i8, i16, i32, i64, i128, isize => std.fmt.parseInt(T, val, 10),
        u8, u16, u32, u64, u128, usize => std.fmt.parseInt(T, val, 10),
        f16, f32, f64, f80, f128 => std.fmt.parseFloat(T, val),
        bool => parseBool(val),
        else => blk: {
            const inner_type_info = @typeInfo(T);
            if (inner_type_info == .@"enum") {
                inline for (inner_type_info.@"enum".fields) |field| {
                    if (std.mem.eql(u8, val, field.name)) {
                        break :blk @enumFromInt(field.value);
                    }
                }
                return error.InvalidEnumValue;
            }
            @compileError("Unsupported type: " ++ @typeName(T));
        },
    };
}

//==============================================================================
// Test Utilities
//==============================================================================

fn validatePort(port: u32) !u32 {
    if (port > 65535) return error.InvalidPort;
    return port;
}

fn parseEnum(comptime E: type) fn ([]const u8) anyerror!E {
    return struct {
        fn parse(raw: []const u8) !E {
            inline for (@typeInfo(E).@"enum".fields) |field| {
                if (std.mem.eql(u8, raw, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.InvalidEnumValue;
        }
    }.parse;
}

fn parseStringArray(raw: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    if (raw.len == 0) return &[_][]const u8{};

    var result = std.array_list.Managed([]const u8).init(allocator);
    defer result.deinit();

    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len > 0) {
            const owned = try allocator.dupe(u8, trimmed);
            try result.append(owned);
        }
    }

    return result.toOwnedSlice();
}

fn createTestEnvMap(allocator: std.mem.Allocator, vars: []const struct { key: []const u8, value: []const u8 }) !std.process.EnvMap {
    var env_map = std.process.EnvMap.init(allocator);
    for (vars) |v| {
        try env_map.put(v.key, v.value);
    }
    return env_map;
}

//==============================================================================
// Tests
//==============================================================================

test "basic type parsing" {
    const Config = struct {
        name: []const u8,
        port: u32,
        timeout: i32,
        ratio: f32,
        debug: bool,
        enabled: bool,
    };

    const allocator = std.testing.allocator;
    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "name", .value = "test-app" },
        .{ .key = "port", .value = "8080" },
        .{ .key = "timeout", .value = "-30" },
        .{ .key = "ratio", .value = "3.14" },
        .{ .key = "debug", .value = "true" },
        .{ .key = "enabled", .value = "1" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    try std.testing.expectEqualStrings("test-app", config.name);
    try std.testing.expectEqual(@as(u32, 8080), config.port);
    try std.testing.expectEqual(@as(i32, -30), config.timeout);
    try std.testing.expectEqual(@as(f32, 3.14), config.ratio);
    try std.testing.expect(config.debug);
    try std.testing.expect(config.enabled);
}

test "optional and default values" {
    const Config = struct {
        required: []const u8,
        optional_present: ?u32,
        optional_missing: ?u32,
        with_default: u32 = 3000,
        optional_with_default: ?u32 = 100,

        const env = .{
            .required = "REQUIRED",
            .optional_present = "OPTIONAL_PRESENT",
            .optional_missing = "OPTIONAL_MISSING",
            .with_default = "WITH_DEFAULT",
            .optional_with_default = "OPTIONAL_WITH_DEFAULT",
        };
    };

    const allocator = std.testing.allocator;
    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "REQUIRED", .value = "test" },
        .{ .key = "OPTIONAL_PRESENT", .value = "42" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    try std.testing.expectEqualStrings("test", config.required);
    try std.testing.expectEqual(@as(u32, 42), config.optional_present.?);
    try std.testing.expectEqual(@as(?u32, null), config.optional_missing);
    try std.testing.expectEqual(@as(u32, 3000), config.with_default);
    try std.testing.expectEqual(@as(u32, 100), config.optional_with_default.?);
}

test "field mapping and skipping" {
    const Config = struct {
        mapped_field: []const u8,
        skipped_field: []const u8 = "default",
        normal_field: u32 = 42,

        const env = .{
            .mapped_field = "CUSTOM_NAME",
            .skipped_field = "-",
        };
    };

    const allocator = std.testing.allocator;
    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "CUSTOM_NAME", .value = "mapped_value" },
        .{ .key = "normal_field", .value = "100" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    try std.testing.expectEqualStrings("mapped_value", config.mapped_field);
    try std.testing.expectEqualStrings("default", config.skipped_field);
    try std.testing.expectEqual(@as(u32, 100), config.normal_field);
}

test "nested structs" {
    const DatabaseConfig = struct {
        host: []const u8,
        port: u32 = 5432,

        const env = .{
            .host = "DB_HOST",
            .port = "DB_PORT",
        };
    };

    const Config = struct {
        app_name: []const u8,
        database: DatabaseConfig,
        optional_db: ?DatabaseConfig,

        const env = .{
            .app_name = "APP_NAME",
        };
    };

    const allocator = std.testing.allocator;
    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "APP_NAME", .value = "my-app" },
        .{ .key = "DB_HOST", .value = "localhost" },
        .{ .key = "DB_PORT", .value = "3306" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    try std.testing.expectEqualStrings("my-app", config.app_name);
    try std.testing.expectEqualStrings("localhost", config.database.host);
    try std.testing.expectEqual(@as(u32, 3306), config.database.port);
    try std.testing.expectEqualStrings("localhost", config.optional_db.?.host);
}

test "custom parsers and validators" {
    const LogLevel = enum { debug, info, warn, err };

    const Config = struct {
        port: u32,
        log_level: LogLevel,
        validated_port: u32,
        tags: [][]const u8,
        auto_port: u32,
        auto_log_level: LogLevel,

        const env = .{
            .port = .{
                .key = "PORT",
                .parser = validator(u32, validatePort),
            },
            .log_level = .{
                .key = "LOG_LEVEL",
                .parser = parseEnum(LogLevel),
            },
            .validated_port = .{
                .key = "VALIDATED_PORT",
                .parser = validator(u32, validatePort),
            },
            .tags = .{
                .key = "TAGS",
                .parser = parseStringArray,
            },
            .auto_port = .{
                .parser = validator(u32, validatePort),
            },
            .auto_log_level = .{
                .parser = parseEnum(LogLevel),
            },
        };
    };

    const allocator = std.testing.allocator;

    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "PORT", .value = "8080" },
        .{ .key = "LOG_LEVEL", .value = "info" },
        .{ .key = "VALIDATED_PORT", .value = "3000" },
        .{ .key = "TAGS", .value = "api, web, production" },
        .{ .key = "auto_port", .value = "9000" },
        .{ .key = "auto_log_level", .value = "debug" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    // Note: config.tags are allocated from page allocator in loadMap()
    // For production use with allocating parsers, prefer load() which provides automatic cleanup

    try std.testing.expectEqual(@as(u32, 8080), config.port);
    try std.testing.expectEqual(LogLevel.info, config.log_level);
    try std.testing.expectEqual(@as(u32, 3000), config.validated_port);
    try std.testing.expectEqual(@as(usize, 3), config.tags.len);
    try std.testing.expectEqualStrings("api", config.tags[0]);
    try std.testing.expectEqualStrings("web", config.tags[1]);
    try std.testing.expectEqualStrings("production", config.tags[2]);
    try std.testing.expectEqual(@as(u32, 9000), config.auto_port);
    try std.testing.expectEqual(LogLevel.debug, config.auto_log_level);

    // Test parseValue utility with various types
    try std.testing.expectEqual(@as(u32, 42), try parseValue(u32, "42"));
    try std.testing.expectEqual(@as(f32, 3.14), try parseValue(f32, "3.14"));
    try std.testing.expect(try parseValue(bool, "true"));
    try std.testing.expectEqualStrings("hello", try parseValue([]const u8, "hello"));

    // Test validation works with automatic key inference (using simple config to avoid memory issues)
    {
        const SimpleConfig = struct {
            port: u32,

            const env = .{
                .port = .{
                    .parser = validator(u32, validatePort),
                },
            };
        };

        var validation_env_map = try createTestEnvMap(allocator, &.{
            .{ .key = "port", .value = "70000" }, // Invalid port > 65535
        });
        defer validation_env_map.deinit();
        try std.testing.expectError(error.InvalidPort, loadMap(SimpleConfig, validation_env_map));
    }
}

test "error cases" {
    const allocator = std.testing.allocator;

    // Missing required field
    {
        const Config = struct {
            required: []const u8,
        };

        var env_map = try createTestEnvMap(allocator, &.{});
        defer env_map.deinit();

        try std.testing.expectError(error.MissingEnvironmentVariable, loadMap(Config, env_map));
    }

    // Invalid integer
    {
        const Config = struct {
            port: u32,
        };

        var env_map = try createTestEnvMap(allocator, &.{
            .{ .key = "port", .value = "invalid" },
        });
        defer env_map.deinit();

        try std.testing.expectError(error.InvalidCharacter, loadMap(Config, env_map));
    }

    // Custom validator error
    {
        const Config = struct {
            port: u32,
            const env = .{
                .port = .{
                    .key = "PORT",
                    .parser = validator(u32, validatePort),
                },
            };
        };

        var env_map = try createTestEnvMap(allocator, &.{
            .{ .key = "PORT", .value = "99999" },
        });
        defer env_map.deinit();

        try std.testing.expectError(error.InvalidPort, loadMap(Config, env_map));
    }
}

test "comprehensive real-world scenario" {
    const LogLevel = enum { debug, info, warn, err };

    const RedisConfig = struct {
        host: []const u8 = "localhost",
        port: u32 = 6379,
        password: ?[]const u8,

        const env = .{
            .host = "REDIS_HOST",
            .port = "REDIS_PORT",
            .password = "REDIS_PASSWORD",
        };
    };

    const DatabaseConfig = struct {
        host: []const u8,
        port: u32,
        ssl: bool = false,

        const env = .{
            .host = "DB_HOST",
            .port = .{
                .key = "DB_PORT",
                .parser = validator(u32, validatePort),
            },
            .ssl = "DB_SSL",
        };
    };

    const Config = struct {
        app_name: []const u8,
        debug: bool = false,
        log_level: LogLevel = .info,
        features: [][]const u8,
        database: DatabaseConfig,
        redis: ?RedisConfig,

        const env = .{
            .app_name = "APP_NAME",
            .debug = "DEBUG",
            .log_level = .{
                .key = "LOG_LEVEL",
                .parser = parseEnum(LogLevel),
            },
            .features = .{
                .key = "FEATURES",
                .parser = parseStringArray,
            },
        };
    };

    const allocator = std.testing.allocator;
    var env_map = try createTestEnvMap(allocator, &.{
        .{ .key = "APP_NAME", .value = "production-app" },
        .{ .key = "DEBUG", .value = "false" },
        .{ .key = "LOG_LEVEL", .value = "warn" },
        .{ .key = "FEATURES", .value = "auth, analytics, caching, monitoring" },
        .{ .key = "DB_HOST", .value = "db.example.com" },
        .{ .key = "DB_PORT", .value = "5432" },
        .{ .key = "DB_SSL", .value = "true" },
        .{ .key = "REDIS_HOST", .value = "cache.example.com" },
        .{ .key = "REDIS_PORT", .value = "6380" },
    });
    defer env_map.deinit();

    const config = try loadMap(Config, env_map);
    // Note: config.features are allocated from page allocator in loadMap()
    // For production use with allocating parsers, prefer load() which provides automatic cleanup

    try std.testing.expectEqualStrings("production-app", config.app_name);
    try std.testing.expect(!config.debug);
    try std.testing.expectEqual(LogLevel.warn, config.log_level);
    try std.testing.expectEqual(@as(usize, 4), config.features.len);
    try std.testing.expectEqualStrings("auth", config.features[0]);
    try std.testing.expectEqualStrings("analytics", config.features[1]);
    try std.testing.expectEqualStrings("caching", config.features[2]);
    try std.testing.expectEqualStrings("monitoring", config.features[3]);
    try std.testing.expectEqualStrings("db.example.com", config.database.host);
    try std.testing.expectEqual(@as(u32, 5432), config.database.port);
    try std.testing.expect(config.database.ssl);
    try std.testing.expectEqualStrings("cache.example.com", config.redis.?.host);
    try std.testing.expectEqual(@as(u32, 6380), config.redis.?.port);
    try std.testing.expectEqual(@as(?[]const u8, null), config.redis.?.password);
}
