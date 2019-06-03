#include <eosio/chain/checktime_timer.hpp>
#include <eosio/chain/checktime_timer_calibrate.hpp>

#include <fc/time.hpp>
#include <fc/fwd_impl.hpp>
#include <fc/exception/exception.hpp>

#include <mutex>
#include <thread>

#include <sys/event.h>

namespace eosio { namespace chain {

//a kqueue & thread is shared for all checktime_timer instances, and since we want these
// available for the checktime_timer_calibrate instance that we want to happen on process
// start (and not at some first usage of checktime_timer), these gotta go here
static std::mutex timer_ref_mutex;
static unsigned next_timerid;
static unsigned refcount;
static int kqueue_fd;
static std::thread kevent_thread;

//last, because need the thread & mutex above initialized first
static checktime_timer_calibrate the_calibrate;

struct checktime_timer::impl {
   uint64_t timerid;

   constexpr static uint64_t quit_event_id = 1;
};

checktime_timer::checktime_timer() {
   static_assert(sizeof(impl) <= fwd_size);

   std::lock_guard guard(timer_ref_mutex);

   if(refcount++ == 0) {
      kqueue_fd = kqueue();

      FC_ASSERT(kqueue_fd != -1, "failed to create kqueue");

      //set up a EVFILT_USER which will be signaled to shut down the thread
      struct kevent64_s quit_event;
      EV_SET64(&quit_event, impl::quit_event_id, EVFILT_USER, EV_ADD|EV_ENABLE, NOTE_FFNOP, 0, 0, 0, 0);
      FC_ASSERT(kevent64(kqueue_fd, &quit_event, 1, NULL, 0, KEVENT_FLAG_IMMEDIATE, NULL) == 0, "failed to create quit event");

      kevent_thread = std::thread([]() {
         while(true) {
            struct kevent64_s anEvent;
            int c = kevent64(kqueue_fd, NULL, 0, &anEvent, 1, 0, NULL);

            if(c == 1 && anEvent.filter == EVFILT_TIMER)
               *(sig_atomic_t*)(anEvent.udata) = 1;
            else if(c == 1 && anEvent.filter == EVFILT_USER)
               return;
            else if(c == -1 && errno == EINTR)
               continue;
            else if(c == -1)
               return; //?? not much we can do now
         }
      });
   }

   //a kludge until something better: print stats only after calibration completes
   // (which can be inferred on if timer_overhead in non-zero); because otherwise fc logging
   // may not be ready
   if(the_calibrate.timer_overhead())
      the_calibrate.print_stats();

   my->timerid = next_timerid++;
}

checktime_timer::~checktime_timer() {
   stop();
   if(std::lock_guard guard(timer_ref_mutex); --refcount == 0) {
      struct kevent64_s signal_quit_event;
      EV_SET64(&signal_quit_event, impl::quit_event_id, EVFILT_USER, 0, NOTE_TRIGGER, 0, 0, 0, 0);

      if(kevent64(kqueue_fd, &signal_quit_event, 1, NULL, 0, KEVENT_FLAG_IMMEDIATE, NULL) != -1)
         kevent_thread.join();
      close(kqueue_fd);
   }
}

void checktime_timer::start(fc::time_point tp) {
   if(tp == fc::time_point::maximum()) {
      expired = 0;
      return;
   }
   if(!the_calibrate.use_timer()) {
      expired = 1;
      return;
   }
   fc::microseconds x = tp.time_since_epoch() - fc::time_point::now().time_since_epoch();
   ms = (int)x.count()-the_calibrate.timer_overhead();
   if(x.count() <= the_calibrate.timer_overhead())
      expired = 1;
   else {
      struct kevent64_s aTimerEvent;
      EV_SET64(&aTimerEvent, my->timerid, EVFILT_TIMER, EV_ADD|EV_ENABLE|EV_ONESHOT, NOTE_USECONDS|NOTE_CRITICAL, (int)x.count()-the_calibrate.timer_overhead(), (uint64_t)&expired, 0, 0);

      expired = 0;
      if(kevent64(kqueue_fd, &aTimerEvent, 1, NULL, 0, KEVENT_FLAG_IMMEDIATE, NULL) != 0)
         expired = 1;
   }
}

void checktime_timer::stop() {
   if(expired)
      return;

   struct kevent64_s stop_timer_event;
   EV_SET64(&stop_timer_event, my->timerid, EVFILT_TIMER, EV_DELETE, 0, 0, 0, 0, 0);
   kevent64(kqueue_fd, &stop_timer_event, 1, NULL, 0, KEVENT_FLAG_IMMEDIATE, NULL);
   expired = 1;
}

}}