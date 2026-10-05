require 'rails_helper'

RSpec.describe MetaWebhook::UnverifiedWarningThrottle do
  let(:start) { Time.zone.local(2026, 10, 4, 12, 0, 0) }

  before { described_class.reset! }

  it 'asks to warn on the first request' do
    expect(described_class.register('Webhooks::WhatsappController', start)).to eq([true, 1])
  end

  it 'suppresses the following requests inside the hour and counts them' do
    described_class.register('Webhooks::WhatsappController', start)

    expect(described_class.register('Webhooks::WhatsappController', start + 1.minute)).to eq([false, 1])
    expect(described_class.register('Webhooks::WhatsappController', start + 59.minutes)).to eq([false, 2])
  end

  it 'warns again after one hour and reports how many requests were accepted since the last warning' do
    described_class.register('Webhooks::WhatsappController', start)
    described_class.register('Webhooks::WhatsappController', start + 1.minute)
    described_class.register('Webhooks::WhatsappController', start + 2.minutes)

    expect(described_class.register('Webhooks::WhatsappController', start + 1.hour)).to eq([true, 3])
    expect(described_class.register('Webhooks::WhatsappController', start + 1.hour + 1.minute)).to eq([false, 1])
  end

  it 'keeps a separate window per key' do
    described_class.register('Webhooks::WhatsappController', start)

    expect(described_class.register('Webhooks::InstagramController', start + 1.minute)).to eq([true, 1])
  end

  it 'is safe to call from several threads' do
    results = Array.new(8) { Thread.new { Array.new(25) { described_class.register('threads', start) } } }.flat_map(&:value)

    expect(results.count { |should_warn, _| should_warn }).to eq(1)
  end
end
