/*
 * The APU's audio out on Linux: the xa2_* contract of xboxrecomp's
 * apu/apu_xaudio2.h on an SDL3 audio stream. xboxrecomp's POSIX backend
 * (apu/apu_sdl2.c) is SDL2; this is the same backend on the SDL3 the game
 * already uses for its window and pads. Windows keeps apu_xaudio2.c.
 *
 * The APU frame thread hands over one EP period (256 stereo frames) at a
 * time, and the stream's queue paces it (mcpx_apu_pace_step reads
 * xa2_queued_samples). The stream is unbounded; pacing by queue depth holds
 * it at the marks, as with SDL2's SDL_QueueAudio.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <SDL3/SDL.h>
#include "apu_xaudio2.h"

#define RATE     48000
#define CHANNELS 2
#define FRAME    (CHANNELS * (int)sizeof(int16_t))

static SDL_AudioStream *g_stream;
static int      g_buf_samples = 512;   /* RECOMP_AUDIO_BUF_SAMPLES, as XAudio2 */
static int      g_num_bufs = 4;        /* RECOMP_AUDIO_BUF_COUNT */
static int      g_frames_written;
static unsigned g_underruns;
static uint64_t g_samples_queued;
static int      g_dry;
static int64_t  g_underrun_logged_ms;

static int env_int(const char *name, int def, int lo, int hi)
{
    const char *e = getenv(name);
    int v;
    if (!e || !*e) return def;
    v = atoi(e);
    return v < lo ? lo : v > hi ? hi : v;
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int xa2_init(void)
{
    SDL_AudioSpec spec = { SDL_AUDIO_S16, CHANNELS, RATE };
    char frames[16];
    const char *driver;

    if (g_stream) return 1;
    g_buf_samples = env_int("RECOMP_AUDIO_BUF_SAMPLES", 512, 128, 4096);
    g_num_bufs = env_int("RECOMP_AUDIO_BUF_COUNT", 4, 2, 8);
    snprintf(frames, sizeof frames, "%d", g_buf_samples);
    SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, frames);
    if (!SDL_WasInit(SDL_INIT_AUDIO) && !SDL_InitSubSystem(SDL_INIT_AUDIO)) {
        fprintf(stderr, "[SDL3] audio init failed: %s\n", SDL_GetError());
        return 0;
    }
    g_stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, NULL, NULL);
    if (!g_stream) {
        fprintf(stderr, "[SDL3] audio device failed: %s\n", SDL_GetError());
        return 0;
    }
    g_frames_written = 0;
    g_samples_queued = 0;
    g_dry = 0;
    SDL_ResumeAudioStreamDevice(g_stream);
    driver = SDL_GetCurrentAudioDriver();
    fprintf(stderr, "[SDL3] audio initialized: driver %s (%d Hz stereo 16-bit, %d x %d-sample buffers)\n",
            driver ? driver : "?", RATE, g_num_bufs, g_buf_samples);
    return 1;
}

void xa2_shutdown(void)
{
    if (!g_stream) return;
    SDL_DestroyAudioStream(g_stream);
    g_stream = NULL;
    fprintf(stderr, "[SDL3] audio shut down (%d periods written, %u underruns)\n",
            g_frames_written, g_underruns);
}

int xa2_is_active(void)
{
    return g_stream != NULL;
}

int xa2_submit_samples(const int16_t *samples, int num_samples)
{
    if (!g_stream || num_samples <= 0) return 0;
    if (!SDL_PutAudioStreamData(g_stream, samples, num_samples * FRAME)) {
        fprintf(stderr, "[SDL3] SDL_PutAudioStreamData failed: %s\n", SDL_GetError());
        return 0;
    }
    g_frames_written++;
    g_samples_queued += (uint64_t)num_samples;
    return 1;
}

int xa2_get_buffer_size(void)
{
    return g_buf_samples;
}

int xa2_get_buffer_count(void)
{
    return g_num_bufs;
}

/* Samples queued and not yet pulled by the device. Also the underrun
 * detector: an empty queue once audio has started means the device's last
 * pull was short; counted once per dry spell, reported at most once a second.
 * A drain announced by xa2_expect_drain (the frame thread pausing) is not one. */
int xa2_queued_samples(void)
{
    int bytes;

    if (!g_stream) return 0;
    bytes = SDL_GetAudioStreamQueued(g_stream);
    if (bytes < 0) bytes = 0;
    if (bytes == 0 && g_frames_written > 0) {
        if (!g_dry) {
            int64_t now = now_ms();
            g_dry = 1;
            g_underruns++;
            if (now - g_underrun_logged_ms >= 1000) {
                g_underrun_logged_ms = now;
                fprintf(stderr, "[SDL3] underrun x%u\n", g_underruns);
            }
        }
    } else {
        g_dry = 0;
    }
    return bytes / FRAME;
}

void xa2_expect_drain(void)
{
    g_dry = 1;
}

unsigned xa2_underruns(void)
{
    return g_underruns;
}

/* What the device has pulled off the queue. */
uint64_t xa2_samples_played(void)
{
    uint64_t queued;
    int bytes;

    if (!g_stream) return 0;
    bytes = SDL_GetAudioStreamQueued(g_stream);
    queued = bytes > 0 ? (uint64_t)bytes / FRAME : 0;
    return g_samples_queued > queued ? g_samples_queued - queued : 0;
}
