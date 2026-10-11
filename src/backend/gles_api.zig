//! The part of OpenGL ES 3.0 that the backend uses. The functions are looked
//! up when the backend starts, so that building this needs neither the
//! headers nor a library to link against.
//!
//! TODO: Add Vulkan and Metal backends. Until then the desktops run this
//! one too, through ANGLE where there is no OpenGL ES, and looking the
//! functions up here is what keeps CI building for them. An OpenGL backend
//! has next to no use today; this one is meant to stay for phones and some
//! embedded devices.

const std = @import("std");

pub const Enum = c_uint;
pub const Uint = c_uint;
pub const Int = c_int;
pub const Sizei = c_int;
pub const Float = f32;
pub const Boolean = u8;
pub const Bitfield = c_uint;
pub const Char = u8;
pub const Sizeiptr = isize;
pub const Intptr = isize;

/// Returns the function of the current context with the given name, or null.
pub const Loader = *const fn ([*c]const u8) callconv(.c) ?*const fn () callconv(.c) void;

pub const ARRAY_BUFFER = 0x8892;
pub const BLEND = 0x0BE2;
pub const CLAMP_TO_EDGE = 0x812F;
pub const COLOR_ATTACHMENT0 = 0x8CE0;
pub const COLOR_BUFFER_BIT = 0x00004000;
pub const COMPILE_STATUS = 0x8B81;
pub const CONSTANT_ALPHA = 0x8003;
pub const DYNAMIC_DRAW = 0x88E8;
pub const FALSE = 0;
pub const FLOAT = 0x1406;
pub const FRAGMENT_SHADER = 0x8B30;
pub const FRAMEBUFFER = 0x8D40;
pub const FRAMEBUFFER_BINDING = 0x8CA6;
pub const FRAMEBUFFER_COMPLETE = 0x8CD5;
pub const INVALID_INDEX = 0xFFFFFFFF;
pub const LINEAR = 0x2601;
pub const LINEAR_MIPMAP_LINEAR = 0x2703;
pub const LINK_STATUS = 0x8B82;
pub const ONE = 1;
pub const ONE_MINUS_CONSTANT_ALPHA = 0x8004;
pub const ONE_MINUS_SRC_ALPHA = 0x0303;
pub const R8 = 0x8229;
pub const RED = 0x1903;
pub const RGBA = 0x1908;
pub const RGBA8 = 0x8058;
pub const SCISSOR_TEST = 0x0C11;
pub const STREAM_DRAW = 0x88E0;
pub const TEXTURE0 = 0x84C0;
pub const TEXTURE1 = 0x84C1;
pub const TEXTURE2 = 0x84C2;
pub const TEXTURE_2D = 0x0DE1;
pub const TEXTURE_MAG_FILTER = 0x2800;
pub const TEXTURE_MIN_FILTER = 0x2801;
pub const TEXTURE_WRAP_S = 0x2802;
pub const TEXTURE_WRAP_T = 0x2803;
pub const TRIANGLE_STRIP = 0x0005;
pub const UNIFORM_BUFFER = 0x8A11;
pub const UNPACK_ALIGNMENT = 0x0CF5;
pub const UNSIGNED_BYTE = 0x1401;
pub const VERTEX_SHADER = 0x8B31;

pub const Functions = struct {
    ActiveTexture: *const fn (texture: Enum) callconv(.c) void,
    AttachShader: *const fn (program: Uint, shader: Uint) callconv(.c) void,
    BindBuffer: *const fn (target: Enum, buffer: Uint) callconv(.c) void,
    BindBufferBase: *const fn (target: Enum, index: Uint, buffer: Uint) callconv(.c) void,
    BindFramebuffer: *const fn (target: Enum, framebuffer: Uint) callconv(.c) void,
    BindTexture: *const fn (target: Enum, texture: Uint) callconv(.c) void,
    BindVertexArray: *const fn (array: Uint) callconv(.c) void,
    BlendColor: *const fn (red: Float, green: Float, blue: Float, alpha: Float) callconv(.c) void,
    BlendFunc: *const fn (sfactor: Enum, dfactor: Enum) callconv(.c) void,
    BufferData: *const fn (target: Enum, size: Sizeiptr, data: ?*const anyopaque, usage: Enum) callconv(.c) void,
    BufferSubData: *const fn (target: Enum, offset: Intptr, size: Sizeiptr, data: ?*const anyopaque) callconv(.c) void,
    CheckFramebufferStatus: *const fn (target: Enum) callconv(.c) Enum,
    Clear: *const fn (mask: Bitfield) callconv(.c) void,
    ClearColor: *const fn (red: Float, green: Float, blue: Float, alpha: Float) callconv(.c) void,
    CompileShader: *const fn (shader: Uint) callconv(.c) void,
    CreateProgram: *const fn () callconv(.c) Uint,
    CreateShader: *const fn (@"type": Enum) callconv(.c) Uint,
    DeleteBuffers: *const fn (n: Sizei, buffers: [*c]const Uint) callconv(.c) void,
    DeleteFramebuffers: *const fn (n: Sizei, framebuffers: [*c]const Uint) callconv(.c) void,
    DeleteProgram: *const fn (program: Uint) callconv(.c) void,
    DeleteShader: *const fn (shader: Uint) callconv(.c) void,
    DeleteTextures: *const fn (n: Sizei, textures: [*c]const Uint) callconv(.c) void,
    DeleteVertexArrays: *const fn (n: Sizei, arrays: [*c]const Uint) callconv(.c) void,
    Disable: *const fn (cap: Enum) callconv(.c) void,
    DrawArrays: *const fn (mode: Enum, first: Int, count: Sizei) callconv(.c) void,
    DrawArraysInstanced: *const fn (mode: Enum, first: Int, count: Sizei, instancecount: Sizei) callconv(.c) void,
    Enable: *const fn (cap: Enum) callconv(.c) void,
    EnableVertexAttribArray: *const fn (index: Uint) callconv(.c) void,
    FramebufferTexture2D: *const fn (target: Enum, attachment: Enum, textarget: Enum, texture: Uint, level: Int) callconv(.c) void,
    GenBuffers: *const fn (n: Sizei, buffers: [*c]Uint) callconv(.c) void,
    GenFramebuffers: *const fn (n: Sizei, framebuffers: [*c]Uint) callconv(.c) void,
    GenTextures: *const fn (n: Sizei, textures: [*c]Uint) callconv(.c) void,
    GenVertexArrays: *const fn (n: Sizei, arrays: [*c]Uint) callconv(.c) void,
    GenerateMipmap: *const fn (target: Enum) callconv(.c) void,
    GetIntegerv: *const fn (pname: Enum, data: [*c]Int) callconv(.c) void,
    GetProgramInfoLog: *const fn (program: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) callconv(.c) void,
    GetProgramiv: *const fn (program: Uint, pname: Enum, params: [*c]Int) callconv(.c) void,
    GetShaderInfoLog: *const fn (shader: Uint, bufSize: Sizei, length: [*c]Sizei, infoLog: [*c]Char) callconv(.c) void,
    GetShaderiv: *const fn (shader: Uint, pname: Enum, params: [*c]Int) callconv(.c) void,
    GetUniformBlockIndex: *const fn (program: Uint, uniformBlockName: [*c]const Char) callconv(.c) Uint,
    GetUniformLocation: *const fn (program: Uint, name: [*c]const Char) callconv(.c) Int,
    LinkProgram: *const fn (program: Uint) callconv(.c) void,
    PixelStorei: *const fn (pname: Enum, param: Int) callconv(.c) void,
    Scissor: *const fn (x: Int, y: Int, width: Sizei, height: Sizei) callconv(.c) void,
    ShaderSource: *const fn (shader: Uint, count: Sizei, string: [*c]const [*c]const Char, length: [*c]const Int) callconv(.c) void,
    TexImage2D: *const fn (target: Enum, level: Int, internalformat: Int, width: Sizei, height: Sizei, border: Int, format: Enum, @"type": Enum, pixels: ?*const anyopaque) callconv(.c) void,
    TexParameteri: *const fn (target: Enum, pname: Enum, param: Int) callconv(.c) void,
    TexSubImage2D: *const fn (target: Enum, level: Int, xoffset: Int, yoffset: Int, width: Sizei, height: Sizei, format: Enum, @"type": Enum, pixels: ?*const anyopaque) callconv(.c) void,
    Uniform1i: *const fn (location: Int, v0: Int) callconv(.c) void,
    UniformBlockBinding: *const fn (program: Uint, uniformBlockIndex: Uint, uniformBlockBinding: Uint) callconv(.c) void,
    UseProgram: *const fn (program: Uint) callconv(.c) void,
    VertexAttribDivisor: *const fn (index: Uint, divisor: Uint) callconv(.c) void,
    VertexAttribPointer: *const fn (index: Uint, size: Int, @"type": Enum, normalized: Boolean, stride: Sizei, pointer: ?*const anyopaque) callconv(.c) void,
    Viewport: *const fn (x: Int, y: Int, width: Sizei, height: Sizei) callconv(.c) void,

    pub fn load(loader: Loader) !Functions {
        var functions: Functions = undefined;
        inline for (@typeInfo(Functions).@"struct".fields) |field| {
            const function = loader("gl" ++ field.name) orelse {
                std.log.err("gles: {s} is missing", .{"gl" ++ field.name});
                return error.MissingFunction;
            };
            @field(functions, field.name) = @ptrCast(function);
        }
        return functions;
    }
};
