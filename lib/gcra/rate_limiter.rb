module GCRA
  RateLimitInfo = Struct.new(
    :limit,
    :remaining,
    :reset_after,
    :retry_after
  )

  class StoreUpdateFailed < RuntimeError; end

  class RateLimiter
    MAX_ATTEMPTS = 10
    NANO_SECOND = 1_000_000_000

    # rate_period in seconds
    def initialize(store, rate_period, max_burst)
      @store = store
      # Convert from seconds to nanoseconds. Ruby's time types return floats from calculations,
      # which is not what we want. Also, there's no proper type for durations.
      @emission_interval = (rate_period * NANO_SECOND).to_i
      @delay_variation_tolerance = @emission_interval * (max_burst + 1)
      @limit = max_burst + 1
    end

    def limit(key, quantity)
      key = key.to_s unless key.is_a?(String)
      i = 0

      while i < MAX_ATTEMPTS
        # tat refers to the theoretical arrival time that would be expected
        # from equally spaced requests at exactly the rate limit.
        tat_from_store, now = @store.get_with_time(key)

        tat = if tat_from_store.nil?
                now
              else
                tat_from_store
              end

        increment = quantity * @emission_interval

        # new_tat describes the new theoretical arrival if the request would succeed.
        # If we get a `tat` in the past (empty bucket), use the current time instead. Having
        # a delay_variation_tolerance >= 1 makes sure that at least one request with quantity 1 is
        # possible when the bucket is empty.
        new_tat = [now, tat].max + increment

        allow_at_and_after = new_tat - @delay_variation_tolerance
        if now < allow_at_and_after

          info = RateLimitInfo.new
          info.limit = @limit

          # Bucket size in duration minus time left until TAT, divided by the emission interval
          # to get a count
          # This is non-zero when a request with quantity > 1 is limited, but lower quantities
          # are still allowed.
          info.remaining = ((@delay_variation_tolerance - (tat - now)) / @emission_interval).to_i

          # Use `tat` instead of `newTat` - we don't further increment tat for a blocked request
          info.reset_after = (tat - now).to_f / NANO_SECOND

          # There's no point in setting retry_after if a request larger than the maximum quantity
          # is attempted.
          if increment <= @delay_variation_tolerance
            info.retry_after = (allow_at_and_after - now).to_f / NANO_SECOND
          end

          return true, info
        end

        # Time until bucket is empty again
        ttl = new_tat - now

        new_value = new_tat.to_i

        updated = if tat_from_store.nil?
                    @store.set_if_not_exists_with_ttl(key, new_value, ttl)
                  else
                    @store.compare_and_set_with_ttl(key, tat_from_store, new_value, ttl)
                  end

        if updated
          info = RateLimitInfo.new
          info.limit = @limit
          info.remaining = ((@delay_variation_tolerance - ttl) / @emission_interval).to_i
          info.reset_after = ttl.to_f / NANO_SECOND
          info.retry_after = nil

          return false, info
        end

        i += 1
      end

      raise StoreUpdateFailed.new(
        "Failed to store updated rate limit data for key '#{key}' after #{MAX_ATTEMPTS} attempts"
      )
    end

    # Overwrite the stored value for key to that of a bucket that has
    # just overflowed, ignoring any existing stored data.
    def mark_overflowed(key)
      key = key.to_s unless key.is_a?(String)
      i = 0
      while i < MAX_ATTEMPTS
        tat_from_store, now = @store.get_with_time(key)
        new_value = now + @delay_variation_tolerance
        ttl = @delay_variation_tolerance
        updated = if tat_from_store.nil?
                    @store.set_if_not_exists_with_ttl(key, new_value, ttl)
                  else
                    @store.compare_and_set_with_ttl(key, tat_from_store, new_value, ttl)
                  end
        if updated
          return true
        end
        i += 1
      end

      raise StoreUpdateFailed.new(
        "Failed to store updated rate limit data for key '#{key}' after #{MAX_ATTEMPTS} attempts"
      )
    end
  end
end
