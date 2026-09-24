/* clickman — the device core of ClickMan analytics.
 *
 * Single source of truth for the extern-C boundary every platform binding
 * links against. Keep this in lockstep with src/capi.rs.
 *
 * The core is a durable queue on the device. The platform tracks events into
 * it, asks it for a batch when one may be due (on a timer, when the app leaves
 * the foreground, when the network returns), sends the batch over HTTPS itself
 * (POST /v1/batch, Content-Encoding: gzip, docs/PROTOCOL.md) and reports how
 * the send ended. The core decides when a batch is due, keeps it reserved
 * while in flight and retries failures with backoff.
 *
 * Conventions:
 *   - Functions returning int32_t return 0 (or 1, see clickman_take_batch) on
 *     success and -1 on failure; call clickman_last_error() for the reason.
 *   - A clickman_buf of {NULL, 0} holds nothing; any other buffer must be
 *     released exactly once with clickman_buf_free.
 *   - Strings are NUL-terminated UTF-8; JSON arguments are objects. Invalid
 *     input is reported as an error, never a crash. The boundary is
 *     panic-proof.
 *   - Times are Unix milliseconds.
 *
 * Threading:
 *   - A client may be used from any thread; calls are serialized inside.
 *   - clickman_last_error is thread-local; each thread sees only its own.
 */
#ifndef CLICKMAN_H
#define CLICKMAN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct clickman_client clickman_client;

/* Owned byte buffer. */
typedef struct {
  uint8_t *ptr;
  size_t len;
} clickman_buf;

/* A batch to send: the id for clickman_complete_batch, the number of events,
 * and the gzipped JSON body. */
typedef struct {
  uint64_t id;
  uint32_t events;
  clickman_buf body;
} clickman_batch;

/* "clickman-core <version> (protocol v1)". Static; never freed. */
const char *clickman_version(void);

/* The last error on the calling thread, "" after a success. Valid until the
 * next ClickMan call on this thread; never freed. */
const char *clickman_last_error(void);

/* Opens or creates the queue at path. config_json may be NULL for the
 * defaults; otherwise a JSON object with any of flushAt, flushIntervalMs,
 * maxQueue, maxAgeMs, maxBatchEvents, maxBatchBytes, leaseMs, backoffBaseMs,
 * backoffMaxMs. Returns NULL on failure. */
clickman_client *clickman_open(const char *path, const char *config_json);

/* Closes a queue. NULL is ignored. */
void clickman_close(clickman_client *client);

/* Sets the actor of events tracked from now on: the host's user id, 1–256
 * characters. */
int32_t clickman_identify(const clickman_client *client, const char *external_id);

/* Makes events tracked from now on anonymous ("*") and forgets the traits,
 * e.g. after signing out. */
int32_t clickman_reset(const clickman_client *client);

/* Sets the context object (app, device, os, library, locale, timezone)
 * stamped on events tracked from now on. */
int32_t clickman_set_context(const clickman_client *client, const char *context_json);

/* Merges a JSON object into the traits sent as context.traits with events
 * tracked from now on, e.g. {"plan": "pro"}; a null value removes a trait. */
int32_t clickman_set_traits(const clickman_client *client, const char *traits_json);

/* Records a launch of the app: app_installed on the first launch, app_updated
 * on the first launch of a new version or build, then app_opened. version and
 * build are 1-64 characters. */
int32_t clickman_app_launched(const clickman_client *client, const char *version,
                              const char *build, int64_t now_ms);

/* Queues an event. properties_json may be NULL; timestamp_ms is the event
 * time, or 0 for now. */
int32_t clickman_track(const clickman_client *client, const char *event,
                       const char *properties_json, int64_t timestamp_ms);

/* Returns 1 and fills *out when a batch is due, 0 when nothing is due, -1 on
 * error. force sends whatever is waiting. The caller frees out->body with
 * clickman_buf_free and reports the send with clickman_complete_batch. */
int32_t clickman_take_batch(const clickman_client *client, int64_t now_ms, bool force,
                            clickman_batch *out);

/* Reports how sending a batch ended: http_status is the response status, or 0
 * when no response came back; retry_after_ms is the Retry-After delay, or -1
 * when there was none. 2xx, 400, 413 and 415 remove the batch; anything else
 * returns it to the queue behind a growing delay. */
int32_t clickman_complete_batch(const clickman_client *client, uint64_t batch_id,
                                int32_t http_status, int64_t retry_after_ms,
                                int64_t now_ms);

/* Events on the device, in flight or waiting; -1 on error. */
int64_t clickman_pending(const clickman_client *client);

/* Releases a buffer handed out by ClickMan. {NULL, 0} is ignored. */
void clickman_buf_free(clickman_buf buf);

#ifdef __cplusplus
}
#endif

#endif /* CLICKMAN_H */
