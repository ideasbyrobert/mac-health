// Chaos workers: real processes, each wrong in exactly one named way.
//
// Every mode performs the SAME nominal job — complete one unit of work roughly
// every 200ms — so any difference in the counters is caused purely by how the
// work is coordinated, never by how much work there is. That is the whole
// experiment: identical purpose, different coordination, wildly different cost.
//
// Each worker publishes a progress counter in shared memory so an observer can tell
// forward progress from its absence. Without that signal a deadlocked process
// and a healthy blocked one are indistinguishable, which is precisely the point
// the lab exists to make.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <fcntl.h>

static volatile sig_atomic_t running = 1;
static void stop(int _) { (void)_; running = 0; }

// The heartbeat must cost almost nothing, or the instrument dominates the
// measurement: an earlier version rewrote a file per unit of work and inflated
// the healthy baseline by two orders of magnitude. A shared 8-byte counter in
// an mmap'd page costs one store, so what the counters show is the scenario.
static volatile unsigned long long* progress_slot = NULL;
static unsigned long long progress_fallback = 0;

static void open_progress(const char* path) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    if (ftruncate(fd, sizeof(unsigned long long)) != 0) { close(fd); return; }
    void* map = mmap(NULL, sizeof(unsigned long long), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return;
    progress_slot = (volatile unsigned long long*)map;
    *progress_slot = 0;
}

static void did_work(void) {
    if (progress_slot) (*progress_slot)++;
    else progress_fallback++;
}

// ------------------------------------------------------------ event source --
// Stands in for the hardware interrupt a real event-driven program waits on.
static pthread_mutex_t event_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t event_ready_cv = PTHREAD_COND_INITIALIZER;
static int event_ready = 0;

static void* event_source(void* _) {
    (void)_;
    while (running) {
        usleep(200000);
        pthread_mutex_lock(&event_lock);
        event_ready = 1;
        pthread_cond_signal(&event_ready_cv);
        pthread_mutex_unlock(&event_lock);
    }
    // Release a consumer that would otherwise wait forever on shutdown.
    pthread_mutex_lock(&event_lock);
    pthread_cond_broadcast(&event_ready_cv);
    pthread_mutex_unlock(&event_lock);
    return NULL;
}

// ---------------------------------------------------------------- deadlock --
// Two threads take two mutexes in opposite orders. The sleep guarantees the
// interleaving that makes the cycle certain rather than merely possible.
static pthread_mutex_t lock_a = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t lock_b = PTHREAD_MUTEX_INITIALIZER;

static void* ab(void* _) {
    (void)_;
    pthread_mutex_lock(&lock_a);
    usleep(100000);
    pthread_mutex_lock(&lock_b);       // waits for the thread holding B
    did_work();
    pthread_mutex_unlock(&lock_b);
    pthread_mutex_unlock(&lock_a);
    return NULL;
}

static void* ba(void* _) {
    (void)_;
    pthread_mutex_lock(&lock_b);
    usleep(100000);
    pthread_mutex_lock(&lock_a);       // waits for the thread holding A
    did_work();
    pthread_mutex_unlock(&lock_a);
    pthread_mutex_unlock(&lock_b);
    return NULL;
}

// ------------------------------------------------------------ pipe deadlock --
// The defect this repository actually shipped: the parent waits for the child
// to exit before draining the pipe, so once the child fills the ~64KB buffer
// both sides block forever. No mutex is involved; the buffer IS the gate.
static void pipe_deadlock(void) {
    int fds[2];
    if (pipe(fds) != 0) _exit(1);
    pid_t child = fork();
    if (child == 0) {
        close(fds[0]);
        char buf[4096];
        memset(buf, 'x', sizeof buf);
        for (int i = 0; i < 256; i++) {          // 1 MB, far past the buffer
            if (write(fds[1], buf, sizeof buf) < 0) _exit(0);
        }
        close(fds[1]);
        _exit(0);
    }
    close(fds[1]);
    int status;
    waitpid(child, &status, 0);                  // the bug: wait before draining
    char sink[4096];
    while (read(fds[0], sink, sizeof sink) > 0) { }
    did_work();
}

int main(int argc, char** argv) {
    const char* mode = argc > 1 ? argv[1] : "healthy";
    if (argc > 2) open_progress(argv[2]);

    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("%d %s\n", getpid(), mode);

    if (!strcmp(mode, "deadlock")) {
        pthread_t t1, t2;
        pthread_create(&t1, NULL, ab, NULL);
        pthread_create(&t2, NULL, ba, NULL);
        pthread_join(t1, NULL);
        pthread_join(t2, NULL);

    } else if (!strcmp(mode, "pipe-deadlock")) {
        pipe_deadlock();
        while (running) pause();

    } else if (!strcmp(mode, "livelock")) {
        // Spins on a condition that never becomes true. Maximum energy, zero work.
        volatile unsigned long long spin = 0;
        while (running) { spin++; if (spin == 0) did_work(); }

    } else if (!strcmp(mode, "wakeup-storm")) {
        // Correct output, ruinous cost: polls at 1kHz for work that arrives at 5Hz.
        int ticks = 0;
        while (running) {
            usleep(1000);
            if (++ticks >= 200) { ticks = 0; did_work(); }
        }

    } else if (!strcmp(mode, "stalled")) {
        // Chases pointers through a buffer far larger than cache, so nearly
        // every access misses and the pipeline waits on memory.
        size_t n = 64u << 20;                    // 64 MB
        size_t* buf = malloc(n);
        if (!buf) _exit(1);
        size_t count = n / sizeof(size_t);
        for (size_t i = 0; i < count; i++) buf[i] = (i * 1103515245u + 12345u) % count;
        size_t at = 0, steps = 0;
        while (running) {
            at = buf[at];
            if (++steps >= 2000000) { steps = 0; did_work(); }
        }

    } else {  // healthy: block on an event until there is something to do
        // The consumer genuinely blocks: it is off the run queue entirely until
        // another thread signals. The event source here is a timer thread
        // standing in for hardware (a packet, a keystroke) that this lab cannot
        // fabricate — so the process still wakes five times a second, and that
        // arrival rate, not the waiting, is what its cost is made of. The
        // contrast with wakeup-storm is therefore real: identical arrival rate,
        // one waiting for it and one asking for it a thousand times a second.
        pthread_t producer;
        pthread_create(&producer, NULL, event_source, NULL);
        pthread_mutex_lock(&event_lock);
        while (running) {
            while (!event_ready && running) pthread_cond_wait(&event_ready_cv, &event_lock);
            if (!running) break;
            event_ready = 0;
            did_work();
        }
        pthread_mutex_unlock(&event_lock);
    }
    return 0;
}
