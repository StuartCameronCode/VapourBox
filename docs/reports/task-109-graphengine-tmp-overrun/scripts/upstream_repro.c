/*
 * Minimal repro for the upstream report (task #109): zimg master (e2e43d09,
 * graphengine 91c6af4c) writes past the buffer zimg_filter_graph_get_tmp_size()
 * asks for when the graph dithers with ZIMG_DITHER_ERROR_DIFFUSION.
 *
 *   c++ -O1 -g -fsanitize=address -Izimg/src/zimg/api upstream_repro.c <libzimg.a>
 *   ./a.out            -> tmp_size 384, then bytes written past it
 *
 * The buffer is surrounded by a 0xA5 pattern; a correct tmp_size leaves it
 * intact. Under AddressSanitizer use EXACT=1 (no guard), which reports a
 * heap-buffer-overflow in ErrorDiffusion*::init_context.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zimg.h>

int main(void)
{
	const unsigned w = 96, h = 64, slack = 65536;
	const int exact = getenv("EXACT") != NULL;
	zimg_image_format src, dst;
	zimg_graph_builder_params params;

	zimg_image_format_default(&src, ZIMG_API_VERSION);
	src.width = w;
	src.height = h;
	src.pixel_type = ZIMG_PIXEL_WORD; /* GRAY16 -> GRAY8 */
	src.depth = 16;
	src.pixel_range = ZIMG_RANGE_LIMITED;
	dst = src;
	dst.pixel_type = ZIMG_PIXEL_BYTE;
	dst.depth = 8;

	zimg_graph_builder_params_default(&params, ZIMG_API_VERSION);
	params.dither_type = ZIMG_DITHER_ERROR_DIFFUSION;

	zimg_filter_graph *graph = zimg_filter_graph_build(&src, &dst, &params);
	if (!graph) {
		char msg[256];
		zimg_get_last_error(msg, sizeof(msg));
		fprintf(stderr, "build: %s\n", msg);
		return 2;
	}
	size_t tmp_size;
	zimg_filter_graph_get_tmp_size(graph, &tmp_size);

	size_t src_stride = (w * 2 + 63) & ~(size_t)63, dst_stride = (w + 63) & ~(size_t)63;
	void *src_mem, *dst_mem, *block;
	posix_memalign(&src_mem, 64, src_stride * h);
	posix_memalign(&dst_mem, 64, dst_stride * h);
	memset(src_mem, 0x40, src_stride * h);
	posix_memalign(&block, 64, exact ? tmp_size : tmp_size + 2 * slack);
	unsigned char *tmp = (unsigned char *)block + (exact ? 0 : slack);
	if (!exact)
		memset(block, 0xA5, tmp_size + 2 * slack);

	zimg_image_buffer_const sb;
	zimg_image_buffer db;
	memset(&sb, 0, sizeof(sb));
	memset(&db, 0, sizeof(db));
	sb.version = db.version = ZIMG_API_VERSION;
	sb.plane[0].data = src_mem;
	sb.plane[0].stride = (ptrdiff_t)src_stride;
	sb.plane[0].mask = ZIMG_BUFFER_MAX;
	db.plane[0].data = dst_mem;
	db.plane[0].stride = (ptrdiff_t)dst_stride;
	db.plane[0].mask = ZIMG_BUFFER_MAX;

	if (zimg_filter_graph_process(graph, &sb, &db, tmp, NULL, NULL, NULL, NULL)) {
		fprintf(stderr, "process failed\n");
		return 2;
	}

	size_t past = 0, furthest = 0;
	if (!exact) {
		for (size_t i = 0; i < slack; ++i) {
			if (tmp[tmp_size + i] != 0xA5) {
				++past;
				furthest = i + 1;
			}
		}
	}
	printf("tmp_size %zu, bytes changed past it %zu, furthest %zu\n", tmp_size, past, furthest);
	zimg_filter_graph_free(graph);
	return past ? 1 : 0;
}
