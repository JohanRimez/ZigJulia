const std = @import("std");
const sdl = @import("cImport.zig");

// Setup parameters
const refreshrate = 50; //[ms]
const scale = 1.5;
const cutoff = 128;
const maxR2 = 4.0;
const VecSize = 128;

// Types

const vType = @Vector(VecSize, f32);
const vTypeU = @Vector(VecSize, u8);

fn vConst(f: comptime_float) vType {
    return @splat(f);
}
fn vConstU(v: u8) vTypeU {
    return @splat(v);
}
fn vFromFloat(f: f32) vType {
    return @splat(f);
}
fn vFromInt(i: u32) vType {
    return @splat(@floatFromInt(i));
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var prng: std.Random.DefaultPrng = undefined;
var canvaspixels: [*]u8 = undefined;
var vStep: vType = undefined;

// Coordinate transformation screen to complex: xc = xscale * (xs - xmid) / yx = yscale * (ys - ymid)
// xratio = xscale / (width/2) or xratio = 2*xscale/width

fn Kernel(index: usize, xc: f32, yc: f32, xj: f32, yj: f32) void {
    var x: vType = vFromFloat(xc) + vStep;
    var y: vType = vFromFloat(yc);
    var steps: vTypeU = vConstU(0);
    var incr: vTypeU = vConstU(1);
    while (true) {
        const xx = x * x;
        const yy = y * y;
        const rr = xx + yy;
        incr &= @intFromBool(rr < vConst(maxR2));
        incr &= @intFromBool(steps < vConstU(cutoff));
        if (@reduce(.Or, incr) == 0) break;
        steps += incr;
        const twoxy = vConst(2.0) * x * y;
        x = xx - yy + vFromFloat(xj);
        y = twoxy + vFromFloat(yj);
    }
    const result: vType = @as(vType, @floatFromInt(steps)) / vFromInt(cutoff);
    const ChR = ConvU(ChannelR(result));
    const ChG = ConvU(ChannelG(result));
    const ChB = ConvU(ChannelB(result));
    for (0..VecSize) |i| {
        canvaspixels[((index + i) << 2)] = ChR[i];
        canvaspixels[((index + i) << 2) + 1] = ChB[i];
        canvaspixels[((index + i) << 2) + 2] = ChG[i];
        canvaspixels[((index + i) << 2) + 3] = 255;
    }
}

fn ChannelR(v: vType) vType {
    const k = @mod((vConst(5) + vConst(6) * v), vConst(6));
    return vConst(1) - @max(vConst(0), @min(vConst(1), @min(k, vConst(4) - k)));
}
fn ChannelG(v: vType) vType {
    const k = @mod((vConst(3) + vConst(6) * v), vConst(6));
    return vConst(1) - @max(vConst(0), @min(vConst(1), @min(k, vConst(4) - k)));
}
fn ChannelB(v: vType) vType {
    const k = @mod((vConst(1) + vConst(6) * v), vConst(6));
    return vConst(1) - @max(vConst(0), @min(vConst(1), @min(k, vConst(4) - k)));
}

fn ConvU(v: vType) vTypeU {
    return @intFromFloat(v * vConst(255.0));
}

pub fn main() !void {
    // initialise Randomizer
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    prng = std.Random.DefaultPrng.init(seed);
    // initialise SDL
    if (sdl.SDL_Init(sdl.SDL_INIT_TIMER | sdl.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL initialisation error: {s}\n", .{sdl.SDL_GetError()});
        return error.sdl_initialisationerror;
    }
    defer sdl.SDL_Quit();
    // Prepare full screen (stable alternative for linux)
    var dm: sdl.SDL_DisplayMode = undefined;
    if (sdl.SDL_GetDisplayMode(0, 0, &dm) != 0) {
        std.debug.print("SDL GetDisplayMode error: {s}\n", .{sdl.SDL_GetError()});
        return error.sdl_initialisationerror;
    }
    const window: *sdl.SDL_Window = sdl.SDL_CreateWindow(
        "Game window",
        0,
        0,
        dm.w,
        dm.h,
        sdl.SDL_WINDOW_BORDERLESS | sdl.SDL_WINDOW_MAXIMIZED,
    ) orelse {
        std.debug.print("SDL window creation failed: {s}\n", .{sdl.SDL_GetError()});
        return error.sdl_initialisationerror;
    };
    defer sdl.SDL_DestroyWindow(window);
    const canvas: *sdl.SDL_Surface = sdl.SDL_GetWindowSurface(window) orelse {
        std.debug.print("SDL window surface creation failed: {s}\n", .{sdl.SDL_GetError()});
        return error.sld_surfacecreationfailed;
    };

    const width: u32 = @intCast(canvas.w);
    const height: u32 = @intCast(canvas.h);
    const aspect: f32 = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width));
    const xscale: f32 = scale * if (aspect < 1.0) 1.0 / aspect else 1.0;
    const yscale: f32 = scale * if (aspect > 1.0) 1.0 / aspect else 1.0;
    const xratio: f32 = 2.0 * xscale / @as(f32, @floatFromInt(width));
    const yratio: f32 = 2.0 * yscale / @as(f32, @floatFromInt(height));
    const xoffs: f32 = -xratio * @as(f32, @floatFromInt(width >> 1));
    const yoffs: f32 = -yratio * @as(f32, @floatFromInt(height >> 1));
    for (0..VecSize) |index| vStep[index] = xratio * @as(f32, @floatFromInt(index));

    std.debug.print("Window dimensions: {}x{}\n", .{ width, height });
    if (width % VecSize > 0) {
        std.debug.print("Window width ({}) not divisible by Vector Size ({})\n", .{ width, VecSize });
        return error.initialisation;
    }
    canvaspixels = @as([*]u8, @ptrCast(@alignCast(canvas.pixels)));
    const VecWidth: u32 = width / VecSize;
    const xIncr: f32 = xratio * @as(f32, @floatFromInt(VecSize));

    // Tweak background openGL to avoid screen flickering
    if (sdl.SDL_GL_GetCurrentContext() != null) {
        _ = sdl.SDL_GL_SetSwapInterval(1);
        std.debug.print("Adapted current openGL context for vSync\n", .{});
    }

    // Hide mouse
    _ = sdl.SDL_ShowCursor(sdl.SDL_DISABLE);

    var angle: f32 = 0.0;
    const aIncr = 0.005;
    const radius = 0.815;

    var timer = try std.time.Timer.start();
    var stoploop = false;
    var event: sdl.SDL_Event = undefined;
    while (!stoploop) {
        timer.reset();
        _ = sdl.SDL_UpdateWindowSurface(window);
        //
        const xj = radius * @cos(angle);
        const yj = radius * @sin(angle);
        var index: usize = 0;
        var y: f32 = yoffs;
        for (0..height) |_| {
            var x: f32 = xoffs;
            for (0..VecWidth) |_| {
                Kernel(index, x, y, xj, yj);
                x += xIncr;
                index += VecSize;
            }
            y += yratio;
        }
        angle += aIncr;

        //

        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl.SDL_KEYDOWN) stoploop = true;
        }
        const tStop = timer.read() / 1_000_000;
        const lap: u32 = @intCast(tStop);
        if (lap < refreshrate) sdl.SDL_Delay(refreshrate - lap);
    }
}
