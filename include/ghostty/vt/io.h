/**
 * @file io.h
 *
 * Generic IO callbacks for libghostty-vt.
 */

#ifndef GHOSTTY_VT_IO_H
#define GHOSTTY_VT_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

/** @defgroup io I/O
 *
 * Synchronous callback interfaces used by APIs that consume or produce byte
 * streams. The callback and userdata pointers must remain valid for the full
 * lifetime documented by the API receiving a GhosttyReader or GhosttyWriter.
 *
 * @{
 */

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Read bytes from a source.
 *
 * The callback must set @p out_read to a value no greater than @p capacity
 * when returning true. A positive value reports progress; it may be less than
 * capacity and does not indicate end-of-file. A zero value is definitive
 * end-of-file. It must not be used to report temporary input starvation or a
 * would-block condition.
 *
 * Returning false reports a fatal read error and the value of @p out_read is
 * ignored. The library does not inspect or modify errno.
 *
 * All pointer arguments are borrowed and valid only for the duration of the
 * callback. The callback is invoked synchronously on the calling thread.
 *
 * @param userdata Opaque userdata from GhosttyReader
 * @param buffer Destination for read bytes; always non-NULL
 * @param capacity Writable capacity of @p buffer; always greater than zero
 * @param[out] out_read Number of bytes read when returning true; non-NULL
 * @return true for a successful read or end-of-file, false for a fatal error
 */
typedef bool (*GhosttyReaderFn)(
    void* userdata,
    uint8_t* buffer,
    size_t capacity,
    size_t* out_read);

/**
 * Write bytes to a destination.
 *
 * Returning true means all @p len bytes were accepted. Returning false
 * reports a fatal write error. A callback wrapping an interface that permits
 * partial writes must retry internally until the full slice is accepted or
 * an error occurs.
 *
 * On failure, the destination may already contain a prefix of the bytes. The
 * calling operation fails and must not be resumed from that partial output.
 * The library does not inspect or modify errno.
 *
 * @p data is borrowed and valid only for the duration of the callback. The
 * callback is invoked synchronously on the calling thread. Successful return
 * means the bytes were handed to the destination; it does not imply that the
 * destination was flushed or made durable.
 *
 * @param userdata Opaque userdata from GhosttyWriter
 * @param data Source bytes; always non-NULL
 * @param len Number of source bytes; always greater than zero
 * @return true if the complete slice was accepted, false on fatal error
 */
typedef bool (*GhosttyWriterFn)(
    void* userdata,
    const uint8_t* data,
    size_t len);

/**
 * A byte source callback and its opaque context.
 *
 * The struct is passed by value. @p read must be non-NULL.
 */
typedef struct {
    GhosttyReaderFn read;
    void* userdata;
} GhosttyReader;

/**
 * A byte destination callback and its opaque context.
 *
 * The struct is passed by value. @p write must be non-NULL.
 */
typedef struct {
    GhosttyWriterFn write;
    void* userdata;
} GhosttyWriter;

/**
 * Read one MIME-typed representation of some content, streaming its
 * bytes to a writer.
 *
 * The library calls this with the MIME type of the representation it
 * needs. The callback writes all of that representation's data to
 * @p writer, in as many calls to `writer.write(writer.userdata, data,
 * len)` as is convenient (one call with everything or many small
 * pieces both work), and returns true. Nothing written is retained
 * beyond each write call, so the data may be borrowed from anywhere:
 * a pasteboard item, a file being read, a stream.
 *
 * Returning false reports that the data could not be read. If the
 * writer refuses a write (returns false), stop and return false
 * without writing more.
 *
 * All pointer arguments, the mime, and the writer are borrowed and
 * valid only for the duration of the callback. The callback is
 * invoked synchronously on the calling thread. The API receiving the
 * GhosttyMimeReader defines which MIME types are requested, how many
 * times, and any consistency requirements across repeated reads.
 *
 * @param userdata Opaque userdata from GhosttyMimeReader
 * @param mime The MIME type of the representation to read
 * @param writer Where to write the data; valid only during this call
 * @return true once all the data was written, false if it could not
 *         be read or the writer refused a write
 */
typedef bool (*GhosttyMimeReaderFn)(
    void* userdata,
    GhosttyString mime,
    GhosttyWriter writer);

/**
 * A MIME-typed content source callback and its opaque context.
 *
 * The struct is passed by value. @p read must be non-NULL.
 */
typedef struct {
    GhosttyMimeReaderFn read;
    void* userdata;
} GhosttyMimeReader;

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_IO_H */
