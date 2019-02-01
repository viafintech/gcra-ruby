require 'digest/sha1'

module GCRA
  # Redis store, expects all timestamps and durations to be integers with nanoseconds since epoch.
  class RedisStore
    CAS_SCRIPT = <<-EOF.freeze
  local v = redis.call('get', KEYS[1])
  if v == false then
    return redis.error_reply("key does not exist")
  end
  if v ~= ARGV[1] then
    return 0
  end
  redis.call('psetex', KEYS[1], ARGV[3], ARGV[2])
  return 1
  EOF
    CAS_SCRIPT_MISSING_KEY_RESPONSE = 'key does not exist'.freeze
    SCRIPT_NOT_IN_CACHE_RESPOSNE = 'NOSCRIPT No matching script. Please use EVAL.'

    def initialize(redis, key_prefix)
      @redis = redis
      @key_prefix = key_prefix
      @cas_sha = Digest::SHA1.hexdigest(CAS_SCRIPT)
    end

    # Returns the value of the key or nil, if it isn't in the store.
    # Also returns the time from the Redis server, with microsecond precision.
    def get_with_time(key)
      time_response, value = @redis.pipelined do
        @redis.time # returns tuple (seconds since epoch, microseconds)
        @redis.get(@key_prefix + key)
      end
      # Convert tuple to nanoseconds
      time = (time_response[0] * 1_000_000 + time_response[1]) * 1_000
      if value != nil
        value = value.to_i
      end

      return value, time
    end

    # Set the value of key only if it is not already set. Return whether the value was set.
    # Also set the key's expiration (ttl, in seconds).
    def set_if_not_exists_with_ttl(key, value, ttl_nano)
      full_key = @key_prefix + key
      ttl_milli = calculate_ttl_milli(ttl_nano)
      @redis.set(full_key, value, nx: true, px: ttl_milli)
    end

    # Atomically compare the value at key to the old value. If it matches, set it to the new value
    # and return true. Otherwise, return false. If the key does not exist in the store,
    # return false with no error. If the swap succeeds, update the ttl for the key atomically.
    def compare_and_set_with_ttl(key, old_value, new_value, ttl_nano)
      full_key = @key_prefix + key
      retried = false
      begin
        ttl_milli = calculate_ttl_milli(ttl_nano)
        swapped = @redis.evalsha(@cas_sha, keys: [full_key], argv: [old_value, new_value, ttl_milli])
      rescue Redis::CommandError => e
        if e.message == CAS_SCRIPT_MISSING_KEY_RESPONSE
          return false
        elsif e.message == SCRIPT_NOT_IN_CACHE_RESPOSNE && !retried
          @redis.script('load', CAS_SCRIPT)
          retried = true
          retry
        end
        raise
      end

      return swapped == 1
    end

    private

    def calculate_ttl_milli(ttl_nano)
      ttl_milli = ttl_nano / 1_000_000
      # Setting 0 as expiration/ttl would result in an error.
      # Therefore overwrite it and use 1
      if ttl_milli == 0
        return 1
      end
      return ttl_milli
    end
  end
end
