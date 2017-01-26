# GCRA for Ruby

`gcra` is a Ruby implementation of a [generic cell rate algorithm](https://en.wikipedia.org/wiki/Generic_cell_rate_algorithm) (GCRA), ported from the Go implementation [throttled](https://github.com/throttled/throttled). It's useful for rate limiting (e.g. for HTTP requests) and allows weights specified per request.

## Getting Started

gcra currently uses Redis as a data store, although it supports other store implementations.

Add to your `Gemfile`:

```ruby
gem 'gcra'
gem 'redis'
```

Create Redis, RedisStore and RateLimiter instances:

```ruby
require 'redis'
require 'gcra/rate_limiter'
require 'gcra/redis_store'

redis = Redis.new(host: 'localhost', port: 6379, timeout: 0.1)
store = GCRA::RedisStore.new(redis, 'rate-limit-app1:')

rate_period = 0.5  # Two requests per second
max_burst = 10     # Allow 10 additional requests as a burst
limiter = GCRA::RateLimiter.new(store, rate_period, max_burst)
```

* `rate_period`: Period between two requests, allowed as a sustained rate. Example: 0.1 for 10 requests per second
* `max_burst`: Number of requests allowed as a burst in addition to the sustained  rate. If the burst is used up, one additional request allowed as burst 'comes back' after each `rate_period` where no request was made.

Rate limit a request (call this before each request):

```ruby
key = '123'  # e.g. an account identifier
quantity = 1  # the number of requests 'used up' by this request, useful e.g. for batch requests

limit, info = limiter.limit(key, quantity)
# => [false, #<struct GCRA::RateLimitInfo limit=11, remaining=10, reset_after=0.5, retry_after=nil>]
```

* `limit`: `false` means the request was allowed, `true` would mean the request would exceed the limit and should be blocked.
* `info`: `GCRA::RateLimitInfo` contains information that might be useful for your API users. It's a `Struct` with the following fields:
    - `limit`: Contains the number of requests that can be made if no previous requests have been made (or they were long enough ago). That's `max_burst` plus one. The latter is necessary so requests are allowed at all when `max_burst` is set to zero.
    - `remaining`: The number of remaining requests that can be made immediately, i.e. the remaining burst.
    - `reset_after`: The time in seconds until the full burst will be available again.
    - `retry_after`: Set to `nil` if a request is allowed or it otherwise doesn't make sense to retry a request (if `quantity` is larger than `max_burst`). For a blocked request that can be retried later, set to the duration in seconds until the next request with the given quantity will be allowed.

`RateLimiter#limit` tells you whether to limit a request or not, you'll have to react to its response yourself and e.g. return an error message and stop processing if the limit was exceeded.

## License

[MIT](LICENSE)
