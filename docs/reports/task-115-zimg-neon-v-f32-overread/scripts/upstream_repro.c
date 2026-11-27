/*
 * Minimal repro for the upstream draft (task #115): on ARM, zimg's NEON float
 * vertical resize reads filter coefficients past the end of
 * FilterContext::data for a filter of 4 or fewer taps.
 *
 *   c++ -O2 -g -fsanitize=address -Izimg/src/zimg/api -x c upstream_repro.c -x none <libzimg.a>
 *   ./a.out       GRAYS 4x4 -> 4x2, point:     1 tap,  resize_line_v_f32_neon<1, false>
 *   ./a.out up    GRAYS 96x64 -> 96x128, bicubic: 4 taps, resize_line_v_f32_neon<4, false>
 *
 * gcc 13 on aarch64 Linux: heap-buffer-overflow, READ of size 4, 0 bytes after
 * the coefficient vector (rows x 4 floats). Clang drops the unused loads, so
 * it is silent there; the read is in the source either way.
 */
#define _POSIX_C_SOURCE 200112L /* posix_memalign under -std=c11 on glibc */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zimg.h>

static void *xalloc(size_t n)
{
	void *p = NULL;
	if (posix_memalign(&p, 64, n ? n : 1))
		exit(2);
	memset(p, 0, n ? n : 1);
	return p;
}

int main(int argc, char **argv)
{
	const int up = argc > 1 && !strcmp(argv[1], "up");
	const unsigned sw = up ? 96 : 4, sh = up ? 64 : 4, dw = sw, dh = up ? 128 : 2;
	zimg_image_format src, dst;
	zimg_graph_builder_params params;
	char msg[1024];

	zimg_image_format_default(&src, ZIMG_API_VERSION);
	src.width = sw;
	src.height = sh;
	src.pixel_type = ZIMG_PIXEL_FLOAT;
	src.depth = 32;
	src.color_family = ZIMG_COLOR_GREY;
	dst = src;
	dst.width = dw;
	dst.height = dh;

	zimg_graph_builder_params_default(&params, ZIMG_API_VERSION);
	params.resample_filter = up ? ZIMG_RESIZE_BICUBIC : ZIMG_RESIZE_POINT;

	zimg_filter_graph *graph = zimg_filter_graph_build(&src, &dst, &params);
	if (!graph) {
		zimg_get_last_error(msg, sizeof(msg));
		fprintf(stderr, "build: %s\n", msg);
		return 2;
	}
	size_t tmp_size;
	zimg_filter_graph_get_tmp_size(graph, &tmp_size);

	size_t sstride = (sw * 4 + 63) / 64 * 64, dstride = (dw * 4 + 63) / 64 * 64;
	zimg_image_buffer_const sb;
	zimg_image_buffer db;
	memset(&sb, 0, sizeof(sb));
	memset(&db, 0, sizeof(db));
	sb.version = db.version = ZIMG_API_VERSION;
	sb.plane[0].data = xalloc(sstride * sh);
	sb.plane[0].stride = (ptrdiff_t)sstride;
	sb.plane[0].mask = ZIMG_BUFFER_MAX;
	db.plane[0].data = xalloc(dstride * dh);
	db.plane[0].stride = (ptrdiff_t)dstride;
	db.plane[0].mask = ZIMG_BUFFER_MAX;
	void *tmp = xalloc(tmp_size);

	if (zimg_filter_graph_process(graph, &sb, &db, tmp, NULL, NULL, NULL, NULL)) {
		zimg_get_last_error(msg, sizeof(msg));
		fprintf(stderr, "process: %s\n", msg);
		return 2;
	}
	printf("GRAYS %ux%u -> %ux%u %s: processed, tmp_size %zu\n", sw, sh, dw, dh, up ? "bicubic" : "point", tmp_size);
	free(tmp);
	free((void *)sb.plane[0].data);
	free(db.plane[0].data);
	zimg_filter_graph_free(graph);
	return 0;
}
