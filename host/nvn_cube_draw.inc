#include "shader_status.h"
static NvProg *zelda_cube_program(NvProg *program) {
    if (program->z_cube) return program->z_cube;
    NSString *key = program->sh[0]->z_cube_uniform == 1 ? @"48e3901f9b4eb169_b" : @"c3960b272d349125_b";
    NvShader *base = shader_get(key, 0);
    if (!base || base->z_cube_uniform != program->sh[0]->z_cube_uniform) return nil;
    NSString *path = [g_msl_dir stringByAppendingPathComponent:[key stringByAppendingString:@".metallib"]];
    NSData *data = [NSData dataWithContentsOfFile:path]; NSError *error = nil;
    if (!data) return nil;
    id<MTLLibrary> library = shader_ir_load(g_dev, path, data.bytes, data.length, true);
    if (!library) {
        NSString *source = zelda_cube_source([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        if (!source) return nil;
        MTLCompileOptions *options = nil; source = zelda_shader_math(source, &options);
        library = ZELDA_SHADER_BUILD([g_dev newLibraryWithSource:source options:options error:&error]);
    }
    if (!library) { MLOG("Cube pass shader unavailable; retaining single-face passes"); return nil; }
    NvShader *shader = [NvShader new]; shader->fn = [library newFunctionWithName:@"main0"];
    if (!shader->fn) return nil;
    shader->rf = base->rf; shader->ae = base->ae; shader->arg_len = base->arg_len;
    shader->stage = 0; shader->z_cube_uniform = base->z_cube_uniform; shader->z_layered = 1;
    shader->c1buf = base->c1buf; shader->c1_gpu = base->c1_gpu; shader->c1off = base->c1off;
    strlcpy(shader->key, base->key, sizeof shader->key);
    NvProg *result = [NvProg new]; for (int i = 0; i < 6; i++) result->sh[i] = program->sh[i]; result->sh[0] = shader;
    program->z_cube = result; return result;
}
static NvProg *zelda_cube_prepare(NvProg *program, int primitive) {
    static int enabled = -1;
    if (enabled < 0) { const char *value = getenv("ZELDA_CUBE_PASS"); enabled = !value || atoi(value); }   // 0: single-face passes (A/B checks)
    int face = enabled ? zelda_cube_face(&R.rt) : -1;
    // Occlusion counting needs no guard: every face still issues its own draw, reports and resets switch the visibility
    // slot inside a pass (g_vis_cur = -1), and Metal counts samples across all layers, so the reported sums are unchanged.
    // g_vis_on stays 1 after the game's first query, so guarding on it disabled the merge in every real scene.
    if (!z_uniform_gpu || tbdr_on() || primitive != NVN_DRAW_PRIMITIVE_TRIANGLES || S.ds.dt || S.ds.st ||
        z_depth_clear.pending || z_color_clear.count || R.clear_c[0] || R.clear_d || R.clear_s ||
        draw_samples_rt(program)) face = -1;
    NvProg *layered = face >= 0 ? zelda_cube_program(program) : nil;
    if (!layered) face = -1;
    if (g_enc && (z_cube_active != (face >= 0))) rp_flush();
    z_cube_requested = face;
    if (face >= 0) { z_cube_draws++; return layered; }
    return program;
}
