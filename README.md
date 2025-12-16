# @xarunoba/env-struct.zig 🌱

![Static Badge](https://img.shields.io/badge/Made_with-%E2%9D%A4%EF%B8%8F-red?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/Zig-0.15.1-orange?style=for-the-badge&logo=zig) ![GitHub License](https://img.shields.io/github/license/xarunoba/env-struct?style=for-the-badge)

**`env-struct`** — environment variables to typed structs

A Zig library for parsing environment variables directly into typed structs, providing automatic type conversion and validation.

> [!NOTE]
> This library does not read environment variables from files; it only parses existing environment variables into a struct.

> [!WARNING]
> **`env-struct` is currently in v0. Every release might have breaking changes before `v1.0.0`. Make sure to specify the version you'd like to use.**

## Why

Managing configuration with environment variables is common, but environment variables are always strings and require manual parsing and validation. `env-struct` eliminates boilerplate by mapping environment variables directly to typed Zig structs, providing automatic type conversion and validation at load time. This approach improves safety, reduces errors, and makes configuration handling more robust and maintainable.

> [!NOTE]
> This is my first ever Zig project so feel free to contribute and send PRs!

## Features

- ✅ **Type-safe**: Automatically parse environment variables into the correct types
- ✅ **Multiple types**: Strings, integers, floats, booleans, and nested structs
- ✅ **Optional fields**: Support for optional fields with defaults
- ✅ **Flexible mapping**: Fields map to their names by default, optional custom mapping
- ✅ **Skip fields**: Map fields to "-" to explicitly skip environment variable lookup
- ✅ **Flexible boolean parsing**: Parse "true", "1", "yes" (case-insensitive) as true
- ✅ **Custom parsers**: Validation and complex parsing functions for advanced use cases
- ✅ **Custom environment maps**: Load from custom maps for testing

## Installation

### Using `zig fetch` (Recommended)

Add this library to your project using `zig fetch`:

```bash
zig fetch --save "git+https://github.com/xarunoba/env-struct.zig#v0.10.0"
```

Then in your `build.zig`:

```zig
const env_struct = b.dependency("env_struct", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("env_struct", env_struct.module("env_struct"));
```

### Direct Copy

Alternatively, you can directly copy the [`env_struct.zig`](./src/env_struct.zig) file from the `src/` directory into your project and import it locally to prevent any external dependencies:

```zig
const env_struct = @import("env_struct.zig");
```

## Usage

```zig
const std = @import("std");
const env_struct = @import("env_struct");

const Config = struct {
    APP_NAME: []const u8,    // Maps to "APP_NAME" env var
    PORT: u32,               // Maps to "PORT" env var
    DEBUG: bool = false,     // Maps to "DEBUG" env var, defaults to false
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try env_struct.load(Config, allocator);

    std.debug.print("App: {s}\n", .{config.APP_NAME});
    std.debug.print("Port: {}\n", .{config.PORT});
}
```

Set environment variables:
```bash
export APP_NAME="My App"
export PORT="8080"
```

### Custom Mapping

#### Mapping Rules

Fields are mapped to environment variables with these behaviors:

- **Default mapping**: Fields automatically map to environment variables with the same name
- **Custom mapping**: Use the `env` declaration to map fields to different environment variable names
- **Skip mapping**: Map a field to `"-"` to skip environment variable lookup (must have default values or be optional)
- **Field requirements**: Fields without default values must either have corresponding environment variables or be optional
- **Optional env declaration**: The `env` declaration is only needed for custom mappings or parsing/validation

```zig
const Config = struct {
    name: []const u8,
    port: u32,
    debug: bool = false,
    timeout: ?f32 = null,

    const env = .{
        .name = "APP_NAME",
        .port = "PORT",
        .debug = "DEBUG",
        .timeout = "TIMEOUT",
    };
};

const config = try env_struct.load(Config, allocator);
```

Set environment variables:
```bash
export APP_NAME="My App"
export PORT="8080"
```

## Advanced Usage

### Custom Parsers and Validators

The library provides two main approaches for custom parsing:

#### 1. Validators (Recommended for validation)
Use the `validator` function to combine default parsing with custom validation:

```zig
const std = @import("std");
const env_struct = @import("env_struct");

// Simple validation function
fn validatePort(port: u32) !u32 {
    if (port > 65535) return error.InvalidPort;
    return port;
}

const Config = struct {
    port: u32,

    const env = .{
        .port = .{
            .key = "PORT",  // .key can be omitted to use field name automatically
            .parser = env_struct.validator(u32, validatePort),
        },
    };
};
```

#### 2. Full Custom Parsers
For complex parsing logic that doesn't use default parsing:

```zig
// Enum parsing function
const LogLevel = enum { debug, info, warn, err };

fn parseLogLevel(raw: []const u8, allocator: std.mem.Allocator) !LogLevel {
    _ = allocator; // unused in this case
    if (std.mem.eql(u8, raw, "debug")) return .debug;
    if (std.mem.eql(u8, raw, "info")) return .info;
    if (std.mem.eql(u8, raw, "warn")) return .warn;
    if (std.mem.eql(u8, raw, "error")) return .err;
    return error.InvalidLogLevel;
}

const Config = struct {
    port: u32,
    log_level: LogLevel,

    const env = .{
        .port = .{
            .key = "PORT",
            .parser = env_struct.validator(u32, validatePort),
        },
        .log_level = .{
            .key = "LOG_LEVEL",
            .parser = parseLogLevel,
        },
    };
};
```

**Key Points:**
- `.key` is the environment variable name, can be omitted to use the field name
- `.parser` is the custom parser function, can be a validator or a full custom parser
- Use `validator()` when you want default parsing + validation
- Use custom parsers for complex parsing that doesn't follow default rules
- All custom parsers use the signature: `fn(raw: []const u8, allocator: Allocator) !T`
- The `parseValue()` function is available for implementing custom parsers that want to reuse default parsing

### Nested Structs & Complex Configuration

```zig
const Config = struct {
    app_name: []const u8,           // Maps to "app_name" env var
    custom_port: u32,               // Maps to "PORT" env var (custom mapping)
    debug: bool = false,            // Maps to "debug" env var, uses default
    internal_field: []const u8 = "computed",  // Skipped from env lookup
    optional_feature: ?u32,         // Maps to "optional_feature", can be null

    const env = .{
        .custom_port = "PORT",      // Custom environment variable name
        .internal_field = "-",      // Skip environment variable lookup
    };
};
```

### Custom Environment Maps

```zig
const DatabaseConfig = struct {
    host: []const u8,
    port: u32 = 5432,

    const env = .{
        .host = "DB_HOST",
        .port = "DB_PORT",
    };
};

const ServerConfig = struct {
    host: []const u8 = "localhost",
    port: u32,
    database: DatabaseConfig,

    const env = .{
        .host = "SERVER_HOST",
        .port = "SERVER_PORT",
    };
};

// Load from system environment
const config = try env_struct.load(ServerConfig, allocator);

// Or load from custom environment map (useful for testing)
var custom_env = std.process.EnvMap.init(allocator);
defer custom_env.deinit();
try custom_env.put("SERVER_PORT", "3000");
const test_config = try env_struct.loadMap(ServerConfig, custom_env, allocator);
```

## Built-in Parser Supported Types

| Type | Examples | Notes |
|------|----------|-------|
| `[]const u8` | `"hello"` | String values |
| `i8`, `i16`, `i32`, `i64`, `i128`, `isize` | `"42"`, `"-123"` | Signed integers |
| `u8`, `u16`, `u32`, `u64`, `u128`, `usize` | `"42"`, `"255"` | Unsigned integers |
| `f16`, `f32`, `f64`, `f80`, `f128` | `"3.14"` | Floating point |
| `bool` | `"true"`, `"1"`, `"yes"` | Case-insensitive |
| `enum` | `"debug"`, `"info"` | Matches enum field names |
| `?T` | Any valid `T` or missing | Optional types |
| `struct` | N/A | Nested structs |

## API

### `load(comptime T: type, allocator: std.mem.Allocator) !T`
Load configuration from system environment variables.

### `loadMap(comptime T: type, env_map: std.process.EnvMap, allocator: std.mem.Allocator) !T`
Load configuration from a custom environment map.

### `parseValue(comptime T: type, raw_value: []const u8, allocator: std.mem.Allocator) !T`
Parse a raw string value into the specified type. Useful for implementing custom parsers that want to preserve default parsing behavior.

### `validator(comptime T: type, comptime validateFn: anytype) fn([]const u8, std.mem.Allocator) anyerror!T`
Create a validator function that combines default parsing with custom validation. The validation function should have the signature `fn(T) !T`.

### Custom Parser Function Signature

Custom parsers must follow this signature:

```zig
fn parserFunction(raw_value: []const u8, allocator: std.mem.Allocator) !T
```

Where:
- `raw_value`: The raw string from the environment variable
- `allocator`: Memory allocator for dynamic allocations (can be ignored if not needed)
- `T`: The target type to parse into
- Returns the parsed value or an error

### Validator Function Signature

Validator functions used with `validator()` should have this signature:

```zig
fn validatorFunction(value: T) !T
```

Where:
- `value`: The already-parsed value from default parsing
- `T`: The type being validated
- Returns the validated value or an error

## Building

```bash
zig build
```

## Testing

```bash
zig test src/env_struct.zig
```
