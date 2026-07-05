/*
 * mkplayer — assemble a C64 player .acme source into a .bin at build time using
 * the bundled acme (the src/asm sources), the very same assembler CheeseCutter
 * links in for runtime .prg export. This removes any dependency on an installed
 * `acme` command: every platform that can build CheeseCutter can build the
 * player. Output is acme's default CBM format (2-byte load address prefix),
 * identical to `acme -f cbm --outfile out.bin in.acme`.
 *
 * Usage: mkplayer <in.acme> <out.bin>
 */
#include <stdio.h>
#include <stdlib.h>

/* Provided by src/asm/acme.c (the library entry CheeseCutter uses for export). */
extern char *acme_assemble(const char *src, int *length, char *error);

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: %s <in.acme> <out.bin>\n", argv[0]);
		return 2;
	}
	FILE *in = fopen(argv[1], "rb");
	if (!in) { perror(argv[1]); return 1; }
	fseek(in, 0, SEEK_END);
	long n = ftell(in);
	fseek(in, 0, SEEK_SET);
	if (n < 0) { fprintf(stderr, "%s: cannot size input\n", argv[1]); return 1; }
	char *src = malloc((size_t)n + 1);
	if (!src) { fprintf(stderr, "out of memory\n"); return 1; }
	if (fread(src, 1, (size_t)n, in) != (size_t)n) { perror(argv[1]); return 1; }
	src[n] = '\0';
	fclose(in);

	int length = 0;
	char error[1024];
	error[0] = '\0';
	char *out = acme_assemble(src, &length, error);
	if (!out) {
		fprintf(stderr, "acme: %s\n", error[0] ? error : "assembly failed");
		return 1;
	}
	FILE *of = fopen(argv[2], "wb");
	if (!of) { perror(argv[2]); return 1; }
	if (fwrite(out, 1, (size_t)length, of) != (size_t)length) { perror(argv[2]); return 1; }
	fclose(of);
	return 0;
}
