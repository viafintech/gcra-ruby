require 'spec_helper'

require_relative '../../../lib/gcra/rate_limiter'

describe GCRA do
  before(:all) do
    @limit = 5

    @store = TestStore.new
    @limiter = GCRA::RateLimiter.new(@store, 1, @limit - 1)
  end

  start = 0

  cases = {
    # You can never make a request larger than the maximum
    0 => {
      now:           start,
      quantity:      6,
      exp_remaining: 5,
      exp_reset:     0,
      exp_retry:     nil,
      exp_limited:   true
    },
    # Rate limit normal requests appropriately
    1 => {
      now:           start,
      quantity:      1,
      exp_remaining: 4,
      exp_reset:     1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    2 => {
      now:           start,
      quantity:      1,
      exp_remaining: 3,
      exp_reset:     2 * 1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    3 => {
      now:           start,
      quantity:      1,
      exp_remaining: 2,
      exp_reset:     3 * 1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    4 => {
      now:           start,
      quantity:      1,
      exp_remaining: 1,
      exp_reset:     4 * 1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    5 => {
      now:           start,
      quantity:      1,
      exp_remaining: 0,
      exp_reset:     5 * 1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    6 => {
      now:           start,
      quantity:      1,
      exp_remaining: 0,
      exp_reset:     5 * 1.0,
      exp_retry:     1.0,
      exp_limited:   true
    },
    7 => {
      now:           start + (3000 * 1_000_000), # +3000 milliseconds in nanoseconds
      quantity:      1,
      exp_remaining: 2,
      exp_reset:     3,
      exp_retry:     nil,
      exp_limited:   false
    },
    8 => {
      now:           start + (3100 * 1_000_000),
      quantity:      1,
      exp_remaining: 1,
      exp_reset:     3.9,
      exp_retry:     nil,
      exp_limited:   false
    },
    9 => {
      now:           start + (4000 * 1_000_000),
      quantity:      1,
      exp_remaining: 1,
      exp_reset:     4.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    10 => {
      now:           start + (8000 * 1_000_000),
      quantity:      1,
      exp_remaining: 4,
      exp_reset:     1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    11 => {
      now:           start + (9500 * 1_000_000),
      quantity:      1,
      exp_remaining: 4,
      exp_reset:     1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    # Zero-quantity request just peeks at the state
    12 => {
      now:           start + (9500 * 1_000_000),
      quantity:      0,
      exp_remaining: 4,
      exp_reset:     1.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    # High-quantity request uses up more of the limit
    13 => {
      now:           start + (9500 * 1_000_000),
      quantity:      2,
      exp_remaining: 2,
      exp_reset:     3.0,
      exp_retry:     nil,
      exp_limited:   false
    },
    # Large requests cannot exceed limits
    14 => {
      now:           start + (9500 * 1_000_000),
      quantity:      5,
      exp_remaining: 2,
      exp_reset:     3.0,
      exp_retry:     3,
      exp_limited:   true
    }
  }

  # All cases are run consecutively through the same limiter
  cases.each do |i, c|
    it "blocks request #{i}: #{c[:exp_limited]}" do
      @store.now = c[:now]
      limited, info = @limiter.limit('foo', c[:quantity])

      aggregate_failures do
        expect(limited).to eq(c[:exp_limited])
        expect(info.limit).to eq(@limit)
        expect(info.remaining).to eq(c[:exp_remaining])
        expect(info.reset_after).to eq(c[:exp_reset])
        expect(info.retry_after).to eq(c[:exp_retry])
      end
    end
  end

  it 'raises an exception if updating the store fails' do
    limit = 5
    store = TestStore.new
    store.fail_sets = true
    limiter = GCRA::RateLimiter.new(store, 1, limit - 1)

    expect {
      limiter.limit('foo', 1)
    }.to raise_error(
      GCRA::StoreUpdateFailed,
      "Failed to store updated rate limit data for key 'foo' after 10 attempts"
    )
  end

  describe 'mark_overflowed' do
    it 'marks a key with previous data as being out of quota' do
      limit = 5
      rate_period = 1.0 # per second
      store = TestStore.new
      limiter = GCRA::RateLimiter.new(store, rate_period, limit)
      limited, info = limiter.limit('foo', 1)
      expect(limited).to eq(false)
      expect(info.remaining).to eq(limit)

      limiter.mark_overflowed('foo')

      limited, info = limiter.limit('foo', 1)

      expect(limited).to eq(true)
      expect(info.remaining).to eq(0)
      expect(info.retry_after).to eq(rate_period) # try again after the full rate period has elapsed
    end

    it 'marks a key with no previous data as being out of quota' do
      limit = 5
      rate_period = 1.0 # per second
      store = TestStore.new
      limiter = GCRA::RateLimiter.new(store, rate_period, limit)

      limiter.mark_overflowed('foo')

      limited, info = limiter.limit('foo', 1)

      expect(limited).to eq(true)
      expect(info.remaining).to eq(0)
      expect(info.retry_after).to eq(rate_period) # try again after the full rate period has elapsed
    end
  end

  class TestStore
    attr_accessor :now
    attr_accessor :fail_sets

    def initialize
      @now = 0
      @data = {}
      @fail_sets = false
    end

    def get_with_time(key)
      return @data[key], @now
    end

    def set_if_not_exists_with_ttl(key, value, ttl)
      return false if fail_sets

      if @data.has_key?(key)
        return false
      end

      @data[key] = value
      return true
    end

    def compare_and_set_with_ttl(key, old_value, new_value, ttl)
      return false if fail_sets

      if @data[key] != old_value
        return false
      end

      @data[key] = new_value
      return true
    end
  end
end
