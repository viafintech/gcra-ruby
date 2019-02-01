require 'spec_helper'
require 'redis'
require_relative '../../../lib/gcra/rate_limiter'
require_relative '../../../lib/gcra/redis_store'

RSpec.describe GCRA::RedisStore do
  # Needs redis running on localhost:6379 (default port)
  let(:redis)      { Redis.new }
  let(:key_prefix) { 'gcra-ruby-specs:' }
  let(:store)      { described_class.new(redis, key_prefix) }

  def cleanup_redis
    keys = redis.keys("#{key_prefix}*")
    unless keys.empty?
      redis.del(keys)
    end
  end

  before do
    begin
      redis.ping
    rescue Redis::CannotConnectError
      pending('Redis is not running on localhost:6379, skipping')
    end

    cleanup_redis
  end

  after do
    cleanup_redis
  end

  describe '#get_with_time' do
    it 'with a value set, returns time and value' do
      redis.set('gcra-ruby-specs:foo', 1_485_422_362_766_819_000)

      value, time = store.get_with_time('foo')

      expect(value).to eq(1_485_422_362_766_819_000)
      expect(time).to be > 1_000_000_000_000_000_000
      expect(time).to be < 3_000_000_000_000_000_000
    end

    it 'with no value set, returns time and value' do
      value, time = store.get_with_time('foo')

      expect(value).to eq(nil)
      expect(time).to be > 1_000_000_000_000_000_000
      expect(time).to be < 3_000_000_000_000_000_000
    end
  end

  describe '#set_if_not_exists_with_ttl' do
    it 'with an existing key, returns false' do
      redis.set('gcra-ruby-specs:foo', 1_485_422_362_766_819_000)

      did_set = store.set_if_not_exists_with_ttl('foo', 2_000_000_000_000_000_000, 1)

      expect(did_set).to eq(false)
    end

    it 'with no existing key, returns true' do
      did_set = store.set_if_not_exists_with_ttl(
        'foo', 3_000_000_000_000_000_000, 10 * 1_000_000_000
      )

      expect(did_set).to eq(true)
      expect(redis.ttl('gcra-ruby-specs:foo')).to be > 8
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 10
    end

    it 'with a very low ttl (less than 1ms)' do
      did_set = store.set_if_not_exists_with_ttl(
        'foo', 3_000_000_000_000_000_000, 100
      )

      expect(did_set).to eq(true)
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 1
    end
  end

  describe '#compare_and_set_with_ttl' do
    it 'with no existing key, returns false' do
      swapped = store.compare_and_set_with_ttl(
        'foo', 2_000_000_000_000_000_000, 3_000_000_000_000_000_000, 1 * 1_000_000_000
      )

      expect(swapped).to eq(false)
      expect(redis.get('gcra-ruby-specs:foo')).to be_nil
    end

    it 'with an existing key and not matching old value, returns false' do
      redis.set('gcra-ruby-specs:foo', 1_485_422_362_766_819_000)

      swapped = store.compare_and_set_with_ttl(
        'foo', 2_000_000_000_000_000_000, 3_000_000_000_000_000_000, 10 * 1_000_000_000
      )

      expect(swapped).to eq(false)
      expect(redis.get('gcra-ruby-specs:foo')).to eq('1485422362766819000')
    end

    it 'with an existing key and matching old value, returns true' do
      redis.set('gcra-ruby-specs:foo', 2_000_000_000_000_000_000)

      swapped = store.compare_and_set_with_ttl(
        'foo', 2_000_000_000_000_000_000, 3_000_000_000_000_000_000, 10 * 1_000_000_000
      )

      expect(swapped).to eq(true)
      expect(redis.get('gcra-ruby-specs:foo')).to eq('3000000000000000000')
      expect(redis.ttl('gcra-ruby-specs:foo')).to be > 8
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 10
    end

    it 'with an existing key and a very low ttl (less than 1ms)' do
      redis.set('gcra-ruby-specs:foo', 2_000_000_000_000_000_000)

      swapped = store.compare_and_set_with_ttl(
        'foo', 2_000_000_000_000_000_000, 3_000_000_000_000_000_000, 100
      )

      expect(swapped).to eq(true)
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 1
    end

    it 'handles the script cache being purged (gracefully reloads script)' do
      redis.set('gcra-ruby-specs:foo', 2_000_000_000_000_000_000)

      swapped = store.compare_and_set_with_ttl(
        'foo', 2_000_000_000_000_000_000, 3_000_000_000_000_000_000, 10 * 1_000_000_000
      )

      expect(swapped).to eq(true)
      expect(redis.get('gcra-ruby-specs:foo')).to eq('3000000000000000000')
      expect(redis.ttl('gcra-ruby-specs:foo')).to be > 8
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 10

      # purge the script cache, this will trigger an exception branch that reloads the script
      redis.script('flush')

      swapped = store.compare_and_set_with_ttl(
        'foo', 3_000_000_000_000_000_000, 4_000_000_000_000_000_000, 10 * 1_000_000_000
      )

      expect(swapped).to eq(true)
      expect(redis.get('gcra-ruby-specs:foo')).to eq('4000000000000000000')
      expect(redis.ttl('gcra-ruby-specs:foo')).to be > 8
      expect(redis.ttl('gcra-ruby-specs:foo')).to be <= 10
    end
  end

  context 'functional test with RateLimiter' do
    let(:limiter) { GCRA::RateLimiter.new(store, 1, 2) }

    it 'allow and limits properly' do
      # Attempt too high quantity
      limit1, info1 = limiter.limit('foo', 4)

      aggregate_failures do
        expect(limit1).to be true
        expect(info1.limit).to eq(3)
        expect(info1.remaining).to eq(3)
        expect(info1.reset_after).to eq(0.0)
        expect(info1.retry_after).to be_nil
      end

      # Normal request
      limit1, info1 = limiter.limit('foo', 1)

      aggregate_failures do
        expect(limit1).to be false
        expect(info1.limit).to eq(3)
        expect(info1.remaining).to eq(2)
        expect(info1.reset_after).to eq(1.0)
        expect(info1.retry_after).to be_nil
      end

      # Normal request, fills up rest of bucket
      limit1, info1 = limiter.limit('foo', 2)

      aggregate_failures do
        expect(limit1).to be false
        expect(info1.limit).to eq(3)
        expect(info1.remaining).to eq(0)
        expect(info1.reset_after).to be < 3.0
        expect(info1.reset_after).to be > 2.5
        expect(info1.retry_after).to be_nil
      end

      # Normal request, exceeds limit
      limit1, info1 = limiter.limit('foo', 1)

      aggregate_failures do
        expect(limit1).to be true
        expect(info1.limit).to eq(3)
        expect(info1.remaining).to eq(0)
        expect(info1.reset_after).to be < 3.0
        expect(info1.reset_after).to be > 2.0
        expect(info1.retry_after).to be < 1.0
        expect(info1.retry_after).to be > 0.5
      end

      # Allows a normal request after 1 second waiting
      sleep(1)
      limit1, info1 = limiter.limit('foo', 1)

      aggregate_failures do
        expect(limit1).to be false
        expect(info1.limit).to eq(3)
        expect(info1.remaining).to eq(0)
        expect(info1.reset_after).to be < 3.0
        expect(info1.reset_after).to be > 2.0
        expect(info1.retry_after).to be_nil
      end
    end
  end
end
