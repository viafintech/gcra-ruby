module GCRA
  class RedisStore
    CAS_SCRIPT = <<-EOF.freeze
  local v = redis.call('get', KEYS[1])
  if v == false then
    return redis.error_reply("key does not exist")
  end
  if v ~= ARGV[1] then
    return 0
  end
  if ARGV[3] ~= "0" then
    redis.call('setex', KEYS[1], ARGV[3], ARGV[2])
  else
    redis.call('set', KEYS[1], ARGV[2])
  end
  return 1
  EOF
    CAS_SCRIPT_MISSING_KEY_RESPONSE = 'key does not exist'.freeze

    def initialize(redis, key_prefix)
      @redis = redis
      @key_prefix = key_prefix
    end

    # Returns the value of the key or nil, if it isn't in the store.
    # Also returns the time from the Redis server, with microsecond precision.
    def get_with_time(key)
      time_response = @redis.time # returns tuple (seconds since epoch, microseconds)
      # Convert tuple to nanoseconds
      time = (time_response[0] * 1_000_000 + time_response[1]) * 1_000
      value = @redis.get(@key_prefix + key)
      if value != nil
        value = value.to_i
      end

      return value, time
    end

    # Set the value of key only if it is not already set. Return whether the value was set.
    # Also set the key's expiration (ttl, in seconds). The operations are not performed atomically.
    def set_if_not_exists_with_ttl(key, value, ttl)
      full_key = @key_prefix + key
      did_set = @redis.setnx(full_key, value)

      if did_set && ttl > 0
        @redis.expire(full_key, ttl)
      end

      return did_set
    end

    # Atomically compare the value at key to the old value. If it matches, set it to the new value
    # and return true. Otherwise, return false. If the key does not exist in the store,
    # return false with no error. If the swap succeeds, update the ttl for the key atomically.
    def compare_and_set_with_ttl(key, old_value, new_value, ttl)
      full_key = @key_prefix + key
      begin
        swapped = @redis.eval(CAS_SCRIPT, keys: [full_key], argv: [old_value, new_value, ttl])
      rescue Redis::CommandError => e
        if e.message == CAS_SCRIPT_MISSING_KEY_RESPONSE
          return false
        end
        raise
      end

      return swapped == 1
    end
  end
end
