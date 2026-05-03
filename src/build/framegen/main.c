#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
#include <zlib.h>

#define SEPARATOR '\x01'
#define CHUNK_SIZE 16384
#define MAX_FRAMES 1024
#define PATH_SEP '/'

static int is_frame_file(const char *name) {
    size_t len = strlen(name);
    return len > 4 && strcmp(name + len - 4, ".txt") == 0;
}

static int compare_names(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static char *read_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open %s: %s\n", path, strerror(errno));
        return NULL;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = malloc(size);
    if (!buf) {
        return NULL;
    }

    if (fread(buf, 1, size, f) != (size_t)size) {
        fprintf(stderr, "Failed to read %s\n", path);
        return NULL;
    }

    fclose(f);
    *out_size = size;
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <frames_dir> <output_file>\n", argv[0]);
        return 1;
    }

    const char *frames_dir = argv[1];
    const char *output_file = argv[2];

    // Use opendir/readdir instead of scandir for Windows compatibility
    DIR *dir = opendir(frames_dir);
    if (!dir) {
        fprintf(stderr, "Failed to scan directory %s: %s\n", frames_dir, strerror(errno));
        return 1;
    }

    char *names[MAX_FRAMES];
    int n = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!is_frame_file(entry->d_name)) continue;
        if (n >= MAX_FRAMES) {
            fprintf(stderr, "Too many frame files (max %d)\n", MAX_FRAMES);
            closedir(dir);
            return 1;
        }
        names[n] = strdup(entry->d_name);
        if (!names[n]) {
            fprintf(stderr, "Failed to allocate memory\n");
            closedir(dir);
            return 1;
        }
        n++;
    }
    closedir(dir);

    if (n == 0) {
        fprintf(stderr, "No frame files found in %s\n", frames_dir);
        return 1;
    }

    qsort(names, n, sizeof(char *), compare_names);

    size_t total_size = 0;
    char **frame_contents = calloc(n, sizeof(char*));
    size_t *frame_sizes = calloc(n, sizeof(size_t));

    for (int i = 0; i < n; i++) {
        char path[4096];
        snprintf(path, sizeof(path), "%s%c%s", frames_dir, PATH_SEP, names[i]);
        
        frame_contents[i] = read_file(path, &frame_sizes[i]);
        if (!frame_contents[i]) {
            return 1;
        }
        
        total_size += frame_sizes[i];
        if (i < n - 1) total_size++;
    }

    char *joined = malloc(total_size);
    if (!joined) {
        fprintf(stderr, "Failed to allocate joined buffer\n");
        return 1;
    }

    size_t offset = 0;
    for (int i = 0; i < n; i++) {
        memcpy(joined + offset, frame_contents[i], frame_sizes[i]);
        offset += frame_sizes[i];
        if (i < n - 1) {
            joined[offset++] = SEPARATOR;
        }
    }

    uLongf compressed_size = compressBound(total_size);
    unsigned char *compressed = malloc(compressed_size);
    if (!compressed) {
        fprintf(stderr, "Failed to allocate compression buffer\n");
        return 1;
    }

    z_stream stream = {0};
    stream.next_in = (unsigned char*)joined;
    stream.avail_in = total_size;
    stream.next_out = compressed;
    stream.avail_out = compressed_size;

    // Use -MAX_WBITS for raw DEFLATE (no zlib wrapper)
    int ret = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) {
        fprintf(stderr, "deflateInit2 failed: %d\n", ret);
        return 1;
    }

    ret = deflate(&stream, Z_FINISH);
    if (ret != Z_STREAM_END) {
        fprintf(stderr, "deflate failed: %d\n", ret);
        deflateEnd(&stream);
        return 1;
    }

    compressed_size = stream.total_out;
    deflateEnd(&stream);
    
    FILE *out = fopen(output_file, "wb");
    if (!out) {
        fprintf(stderr, "Failed to create %s: %s\n", output_file, strerror(errno));
        return 1;
    }

    if (fwrite(compressed, 1, compressed_size, out) != compressed_size) {
        fprintf(stderr, "Failed to write compressed data\n");
        return 1;
    }

    fclose(out);

    return 0;
}
