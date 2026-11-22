/*
 * tmp_overrun: does zimg_filter_graph_process write outside the temporary
 * buffer whose size zimg_filter_graph_get_tmp_size reported? (task #109)
 *
 * This does what VapourSynth R78's resize does (src/core/vsresize.cpp,
 * real_get_frame): build a graph through the C API, allocate exactly
 * get_tmp_size() bytes, process a whole frame (each field separately when
 * interlaced, the larger of the two sizes), free.
 *
 * Canary mode (default): the buffer gets SLACK guard bytes on each side,
 * filled with a pattern, and after processing every guard byte that changed
 * is counted. Run with two patterns (0xA5, 0x5A) so a write of the pattern
 * value itself is still seen. Independent of the allocator and the CPU.
 * Exact mode (--exact): a buffer of exactly tmp_size bytes and no guards, for
 * AddressSanitizer, valgrind, or glibc's own checks at free().
 *
 * Usage: tmp_overrun [--exact] [--cpu auto64|auto|none] CASES.tsv
 *        tmp_overrun [--exact] [--cpu ...] - NAME SRC SRCWxH DST DSTWxH FILTER DITHER FIELD
 * A case line: name, source format, source size, destination format,
 * destination size, resample filter (point|bilinear|bicubic|spline16|spline36|lanczos),
 * dither (none|ordered|random|error_diffusion), field (p = progressive,
 * i = interlaced: two field graphs, as VapourSynth runs them).
 * A format is NAME[:MATRIX[:RANGE[:TRANSFER[:PRIMARIES]]]], NAME one of gray8,
 * gray16, grays, rgb24, rgb48, rgbs, yuv{420,422,444}p{8,10,12,16}, yuv444ps;
 * MATRIX rgb|709|470bg|170m|2020ncl|unspec; RANGE l|f; TRANSFER and
 * PRIMARIES 709|unspec|linear|st2084|2020|470bg.
 *
 * Prints one TSV line per case: name, cpu, tmp_size, guard bytes changed
 * after the buffer, furthest offset written past its end, guard bytes changed
 * before it, status. Exit status 1 when any case wrote outside the buffer.
 */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zimg.h>

#define SLACK (64 * 1024)
#define ALIGN 64

typedef struct {
	zimg_image_format f;
	unsigned bytes; /* per sample */
	unsigned planes;
} fmt_t;

static int fail(const char *what)
{
	char msg[1024];
	zimg_get_last_error(msg, sizeof(msg));
	fprintf(stderr, "%s: %s\n", what, msg);
	return -1;
}

static int lookup(const char *s, const char *const *names, const int *vals, int *out)
{
	for (int i = 0; names[i]; ++i) {
		if (!strcmp(s, names[i])) {
			*out = vals[i];
			return 0;
		}
	}
	fprintf(stderr, "unknown value '%s'\n", s);
	return -1;
}

static int parse_format(const char *spec, unsigned w, unsigned h, fmt_t *out)
{
	char buf[128];
	char *fields[5] = { 0 };
	int n = 0;
	strncpy(buf, spec, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = 0;
	for (char *tok = strtok(buf, ":"); tok && n < 5; tok = strtok(NULL, ":"))
		fields[n++] = tok;

	zimg_image_format *f = &out->f;
	zimg_image_format_default(f, ZIMG_API_VERSION);
	f->width = w;
	f->height = h;
	f->pixel_range = ZIMG_RANGE_LIMITED;

	const char *name = fields[0];
	unsigned ssw = 0, ssh = 0, depth = 0;
	int is_float = 0;
	if (!strcmp(name, "gray8")) { f->color_family = ZIMG_COLOR_GREY; depth = 8; }
	else if (!strcmp(name, "gray16")) { f->color_family = ZIMG_COLOR_GREY; depth = 16; }
	else if (!strcmp(name, "grays")) { f->color_family = ZIMG_COLOR_GREY; is_float = 1; }
	else if (!strcmp(name, "rgb24")) { f->color_family = ZIMG_COLOR_RGB; depth = 8; }
	else if (!strcmp(name, "rgb48")) { f->color_family = ZIMG_COLOR_RGB; depth = 16; }
	else if (!strcmp(name, "rgbs")) { f->color_family = ZIMG_COLOR_RGB; is_float = 1; }
	else if (!strcmp(name, "yuv444ps")) { f->color_family = ZIMG_COLOR_YUV; is_float = 1; }
	else if (sscanf(name, "yuv%*1[0-9]%*1[0-9]%*1[0-9]p%u", &depth) == 1) {
		f->color_family = ZIMG_COLOR_YUV;
		if (!strncmp(name, "yuv420", 6)) { ssw = 1; ssh = 1; }
		else if (!strncmp(name, "yuv422", 6)) { ssw = 1; }
		else if (strncmp(name, "yuv444", 6)) { fprintf(stderr, "bad format %s\n", name); return -1; }
	} else {
		fprintf(stderr, "bad format %s\n", name);
		return -1;
	}
	f->subsample_w = ssw;
	f->subsample_h = ssh;
	if (is_float) {
		f->pixel_type = ZIMG_PIXEL_FLOAT;
		f->depth = 32;
		out->bytes = 4;
	} else {
		f->pixel_type = depth > 8 ? ZIMG_PIXEL_WORD : ZIMG_PIXEL_BYTE;
		f->depth = depth;
		out->bytes = depth > 8 ? 2 : 1;
	}
	out->planes = f->color_family == ZIMG_COLOR_GREY ? 1 : 3;
	f->matrix_coefficients = f->color_family == ZIMG_COLOR_RGB ? ZIMG_MATRIX_RGB : ZIMG_MATRIX_BT709;
	if (f->color_family == ZIMG_COLOR_RGB)
		f->pixel_range = ZIMG_RANGE_FULL;

	static const char *const mnames[] = { "rgb", "709", "470bg", "170m", "2020ncl", "unspec", 0 };
	static const int mvals[] = { ZIMG_MATRIX_RGB, ZIMG_MATRIX_BT709, ZIMG_MATRIX_BT470_BG, ZIMG_MATRIX_ST170_M,
	                             ZIMG_MATRIX_BT2020_NCL, ZIMG_MATRIX_UNSPECIFIED };
	static const char *const tnames[] = { "709", "unspec", "linear", "st2084", "2020", "470bg", 0 };
	static const int tvals[] = { ZIMG_TRANSFER_BT709, ZIMG_TRANSFER_UNSPECIFIED, ZIMG_TRANSFER_LINEAR,
	                             ZIMG_TRANSFER_ST2084, ZIMG_TRANSFER_BT2020_10, ZIMG_TRANSFER_BT470_BG };
	static const int pvals[] = { ZIMG_PRIMARIES_BT709, ZIMG_PRIMARIES_UNSPECIFIED, ZIMG_PRIMARIES_BT709,
	                             ZIMG_PRIMARIES_BT709, ZIMG_PRIMARIES_BT2020, ZIMG_PRIMARIES_BT470_BG };
	int v;
	if (fields[1]) {
		if (lookup(fields[1], mnames, mvals, &v)) return -1;
		f->matrix_coefficients = (zimg_matrix_coefficients_e)v;
	}
	if (fields[2]) {
		if (!strcmp(fields[2], "l")) f->pixel_range = ZIMG_RANGE_LIMITED;
		else if (!strcmp(fields[2], "f")) f->pixel_range = ZIMG_RANGE_FULL;
		else { fprintf(stderr, "bad range %s\n", fields[2]); return -1; }
	}
	if (fields[3]) {
		if (lookup(fields[3], tnames, tvals, &v)) return -1;
		f->transfer_characteristics = (zimg_transfer_characteristics_e)v;
	}
	if (fields[4]) {
		if (lookup(fields[4], tnames, pvals, &v)) return -1;
		f->color_primaries = (zimg_color_primaries_e)v;
	}
	return 0;
}

typedef struct {
	unsigned char *data[3];
	ptrdiff_t stride[3];
	unsigned rows[3];
} frame_t;

static void *xalloc(size_t n)
{
	void *p = NULL;
	if (posix_memalign(&p, ALIGN, n ? n : 1)) {
		perror("posix_memalign");
		exit(2);
	}
	return p;
}

static void alloc_frame(const fmt_t *fmt, frame_t *fr, int fill, uint32_t seed)
{
	for (unsigned p = 0; p < fmt->planes; ++p) {
		unsigned w = p ? fmt->f.width >> fmt->f.subsample_w : fmt->f.width;
		unsigned h = p ? fmt->f.height >> fmt->f.subsample_h : fmt->f.height;
		size_t stride = ((size_t)w * fmt->bytes + ALIGN - 1) / ALIGN * ALIGN;
		fr->data[p] = xalloc(stride * h);
		fr->stride[p] = (ptrdiff_t)stride;
		fr->rows[p] = h;
		memset(fr->data[p], 0, stride * h);
		if (!fill)
			continue;
		for (unsigned y = 0; y < h; ++y) {
			for (unsigned x = 0; x < w; ++x) {
				seed = seed * 1664525u + 1013904223u;
				unsigned char *px = fr->data[p] + y * stride + (size_t)x * fmt->bytes;
				if (fmt->bytes == 4) {
					float v = (seed >> 8) / 16777216.0f;
					if (fmt->f.color_family == ZIMG_COLOR_YUV && p)
						v -= 0.5f;
					memcpy(px, &v, 4);
				} else if (fmt->bytes == 2) {
					uint16_t v = (uint16_t)((seed >> 16) & ((1u << fmt->f.depth) - 1));
					memcpy(px, &v, 2);
				} else {
					*px = (unsigned char)(seed >> 24);
				}
			}
		}
	}
}

static void free_frame(const fmt_t *fmt, frame_t *fr)
{
	for (unsigned p = 0; p < fmt->planes; ++p)
		free(fr->data[p]);
}

typedef struct {
	size_t tmp_size;
	size_t tail_changed, tail_max, head_changed;
} result_t;

/* Field phase 0/1 for interlaced, -1 for progressive. */
static void field_buffers(const fmt_t *sf, const frame_t *src, const fmt_t *df, const frame_t *dst, int phase,
                          zimg_image_buffer_const *sb, zimg_image_buffer *db)
{
	memset(sb, 0, sizeof(*sb));
	memset(db, 0, sizeof(*db));
	sb->version = ZIMG_API_VERSION;
	db->version = ZIMG_API_VERSION;
	for (unsigned p = 0; p < sf->planes; ++p) {
		int ph = phase < 0 ? 0 : phase;
		sb->plane[p].data = src->data[p] + ph * src->stride[p];
		sb->plane[p].stride = src->stride[p] * (phase < 0 ? 1 : 2);
		sb->plane[p].mask = ZIMG_BUFFER_MAX;
	}
	for (unsigned p = 0; p < df->planes; ++p) {
		int ph = phase < 0 ? 0 : phase;
		db->plane[p].data = dst->data[p] + ph * dst->stride[p];
		db->plane[p].stride = dst->stride[p] * (phase < 0 ? 1 : 2);
		db->plane[p].mask = ZIMG_BUFFER_MAX;
	}
}

static int run_case(char **a, zimg_cpu_type_e cpu, int exact, const char *cpu_name)
{
	const char *name = a[0];
	unsigned sw, sh, dw, dh;
	if (sscanf(a[2], "%ux%u", &sw, &sh) != 2 || sscanf(a[4], "%ux%u", &dw, &dh) != 2) {
		fprintf(stderr, "%s: bad size\n", name);
		return -1;
	}
	int interlaced = !strcmp(a[7], "i");

	fmt_t sf, df;
	if (parse_format(a[1], sw, sh, &sf) || parse_format(a[3], dw, dh, &df))
		return -1;

	zimg_graph_builder_params params;
	zimg_graph_builder_params_default(&params, ZIMG_API_VERSION);
	static const char *const fnames[] = { "point", "bilinear", "bicubic", "spline16", "spline36", "lanczos", 0 };
	static const int fvals[] = { ZIMG_RESIZE_POINT, ZIMG_RESIZE_BILINEAR, ZIMG_RESIZE_BICUBIC,
	                             ZIMG_RESIZE_SPLINE16, ZIMG_RESIZE_SPLINE36, ZIMG_RESIZE_LANCZOS };
	static const char *const dnames[] = { "none", "ordered", "random", "error_diffusion", 0 };
	static const int dvals[] = { ZIMG_DITHER_NONE, ZIMG_DITHER_ORDERED, ZIMG_DITHER_RANDOM, ZIMG_DITHER_ERROR_DIFFUSION };
	int v;
	if (lookup(a[5], fnames, fvals, &v)) return -1;
	/* As VapourSynth: chroma uses the luma filter unless told otherwise. */
	params.resample_filter = params.resample_filter_uv = (zimg_resample_filter_e)v;
	if (lookup(a[6], dnames, dvals, &v)) return -1;
	params.dither_type = (zimg_dither_type_e)v;
	params.cpu_type = cpu;
	params.allow_approximate_gamma = 1;

	zimg_filter_graph *graphs[2] = { 0 };
	int ngraphs = interlaced ? 2 : 1;
	size_t tmp_size = 0;
	for (int i = 0; i < ngraphs; ++i) {
		fmt_t s = sf, d = df;
		if (interlaced) {
			s.f.height /= 2;
			d.f.height /= 2;
			s.f.field_parity = d.f.field_parity = i ? ZIMG_FIELD_BOTTOM : ZIMG_FIELD_TOP;
		}
		if (!(graphs[i] = zimg_filter_graph_build(&s.f, &d.f, &params))) {
			fail(name);
			printf("%s\t%s\t-\t-\t-\t-\tbuild-error\n", name, cpu_name);
			return 0;
		}
		size_t sz;
		if (zimg_filter_graph_get_tmp_size(graphs[i], &sz))
			return fail(name);
		if (sz > tmp_size)
			tmp_size = sz;
	}

	frame_t src, dst;
	alloc_frame(&sf, &src, 1, 12345);
	alloc_frame(&df, &dst, 0, 0);

	result_t r = { tmp_size, 0, 0, 0 };
	static const unsigned char patterns[2] = { 0xA5, 0x5A };
	int runs = exact ? 1 : 2;
	for (int run = 0; run < runs; ++run) {
		unsigned char *block, *tmp;
		size_t total = exact ? tmp_size : tmp_size + 2 * SLACK;
		block = xalloc(total);
		tmp = exact ? block : block + SLACK;
		if (!exact)
			memset(block, patterns[run], total);

		/* VapourSynth processes the bottom field first, then the top. */
		for (int i = ngraphs - 1; i >= 0; --i) {
			zimg_image_buffer_const sb;
			zimg_image_buffer db;
			field_buffers(&sf, &src, &df, &dst, interlaced ? i : -1, &sb, &db);
			if (zimg_filter_graph_process(graphs[i], &sb, &db, tmp, NULL, NULL, NULL, NULL)) {
				fail(name);
				free(block);
				printf("%s\t%s\t%zu\t-\t-\t-\tprocess-error\n", name, cpu_name, tmp_size);
				goto out;
			}
		}
		if (!exact) {
			size_t tail_changed = 0, tail_max = 0, head_changed = 0;
			for (size_t k = 0; k < SLACK; ++k) {
				if (block[k] != patterns[run])
					++head_changed;
				if (tmp[tmp_size + k] != patterns[run]) {
					++tail_changed;
					tail_max = k + 1;
				}
			}
			if (tail_changed > r.tail_changed) r.tail_changed = tail_changed;
			if (tail_max > r.tail_max) r.tail_max = tail_max;
			if (head_changed > r.head_changed) r.head_changed = head_changed;
		}
		free(block);
	}
	{
		const char *status = exact ? "ran" : (r.tail_changed || r.head_changed) ? "OVERRUN" : "ok";
		if (exact)
			printf("%s\t%s\t%zu\t-\t-\t-\t%s\n", name, cpu_name, tmp_size, status);
		else
			printf("%s\t%s\t%zu\t%zu\t%zu\t%zu\t%s\n", name, cpu_name, tmp_size, r.tail_changed, r.tail_max,
			       r.head_changed, status);
	}
out:
	for (int i = 0; i < ngraphs; ++i)
		zimg_filter_graph_free(graphs[i]);
	free_frame(&sf, &src);
	free_frame(&df, &dst);
	fflush(stdout);
	return (r.tail_changed || r.head_changed) ? 1 : 0;
}

int main(int argc, char **argv)
{
	int exact = 0;
	zimg_cpu_type_e cpu = ZIMG_CPU_AUTO_64B; /* VapourSynth's default */
	const char *cpu_name = "auto64";
	int i = 1;
	for (; i < argc && argv[i][0] == '-' && argv[i][1]; ++i) {
		if (!strcmp(argv[i], "--exact")) {
			exact = 1;
		} else if (!strcmp(argv[i], "--cpu") && i + 1 < argc) {
			cpu_name = argv[++i];
			if (!strcmp(cpu_name, "auto64")) cpu = ZIMG_CPU_AUTO_64B;
			else if (!strcmp(cpu_name, "auto")) cpu = ZIMG_CPU_AUTO;
			else if (!strcmp(cpu_name, "none")) cpu = ZIMG_CPU_NONE;
			else { fprintf(stderr, "bad --cpu\n"); return 2; }
		} else {
			fprintf(stderr, "unknown option %s\n", argv[i]);
			return 2;
		}
	}
	if (i >= argc) {
		fprintf(stderr, "usage: tmp_overrun [--exact] [--cpu auto64|auto|none] CASES.tsv | - CASE...\n");
		return 2;
	}
	printf("case\tcpu\ttmp_size\ttail_changed\ttail_max\thead_changed\tstatus\n");

	int bad = 0;
	if (!strcmp(argv[i], "-")) {
		if (argc - i - 1 != 8) {
			fprintf(stderr, "a case is 8 fields\n");
			return 2;
		}
		int r = run_case(argv + i + 1, cpu, exact, cpu_name);
		return r < 0 ? 2 : r;
	}
	FILE *fp = fopen(argv[i], "r");
	if (!fp) {
		perror(argv[i]);
		return 2;
	}
	char line[1024];
	while (fgets(line, sizeof(line), fp)) {
		line[strcspn(line, "\r\n")] = 0; /* CRLF or LF */
		if (!line[0] || line[0] == '#')
			continue;
		char *f[8];
		int n = 0;
		for (char *tok = strtok(line, " \t"); tok && n < 8; tok = strtok(NULL, " \t"))
			f[n++] = tok;
		if (n != 8) {
			fprintf(stderr, "skipping malformed line (%d fields)\n", n);
			continue;
		}
		int r = run_case(f, cpu, exact, cpu_name);
		if (r < 0)
			return 2;
		bad |= r;
	}
	fclose(fp);
	return bad;
}
