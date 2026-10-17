import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createSmtpDelivery } from './smtp-delivery.js';

const transportMocks = vi.hoisted(() => ({
  sendMail: vi.fn(),
  close: vi.fn(),
  createTransport: vi.fn(),
}));

vi.mock('nodemailer', () => ({
  default: { createTransport: transportMocks.createTransport },
}));

describe('SMTP recovery delivery', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    transportMocks.createTransport.mockReturnValue({
      sendMail: transportMocks.sendMail,
      close: transportMocks.close,
    });
  });

  it('requires STARTTLS, applies connection limits, and sends a stable-ID reset message', async () => {
    transportMocks.sendMail.mockResolvedValue({ accepted: [{ address: 'person@example.invalid' }], rejected: [] });
    const delivery = createSmtpDelivery({
      host: 'smtp.example.invalid', port: 587, user: 'mailer', password: 'secret', from: 'noreply@example.invalid',
    });
    await delivery.deliver({
      id: 'outbox-123',
      kind: 'password-reset',
      recipient: 'person@example.invalid',
      link: 'https://app.example.invalid/#/reset-password?token=a&b=<unsafe>',
    });

    expect(transportMocks.createTransport).toHaveBeenCalledWith(expect.objectContaining({
      host: 'smtp.example.invalid',
      port: 587,
      secure: false,
      requireTLS: true,
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 20_000,
      tls: { minVersion: 'TLSv1.2' },
      auth: { user: 'mailer', pass: 'secret' },
    }));
    expect(transportMocks.sendMail).toHaveBeenCalledWith(expect.objectContaining({
      to: 'person@example.invalid',
      subject: 'Reset your Simpastil password',
      messageId: '<outbox-123@outbox.simpastil.invalid>',
      text: expect.stringContaining('token=a&b=<unsafe>'),
      html: expect.stringContaining('token=a&amp;b=&lt;unsafe&gt;'),
    }));
    delivery.close();
    expect(transportMocks.close).toHaveBeenCalledOnce();
  });

  it('uses implicit TLS on port 465 and omits incomplete optional authentication', async () => {
    transportMocks.sendMail.mockResolvedValue({ accepted: ['person@example.invalid'] });
    const delivery = createSmtpDelivery({
      host: 'smtp.example.invalid', port: 465, user: 'mailer', from: 'noreply@example.invalid',
    });
    await delivery.deliver({
      id: 'invite-123', kind: 'invite', recipient: 'person@example.invalid', link: 'https://app.example.invalid/#/invite?token=opaque',
    });

    const config = transportMocks.createTransport.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(config).toMatchObject({ secure: true, requireTLS: false });
    expect(config).not.toHaveProperty('auth');
    expect(transportMocks.sendMail).toHaveBeenCalledWith(expect.objectContaining({
      subject: 'Your Simpastil invitation',
      html: expect.stringContaining('Continue setup'),
    }));
  });

  it('classifies only SMTP 5xx RCPT TO rejection as permanent', async () => {
    const delivery = createSmtpDelivery({ host: 'smtp.example.invalid', port: 25, from: 'noreply@example.invalid' });
    transportMocks.sendMail.mockRejectedValueOnce(Object.assign(new Error('private server detail'), {
      responseCode: 550,
      command: 'RCPT TO:<person@example.invalid>',
    }));
    await expect(delivery.deliver({
      id: 'a', kind: 'invite', recipient: 'person@example.invalid', link: 'https://app.example.invalid/#/invite?token=secret',
    })).rejects.toMatchObject({ safeCategory: 'smtp_recipient_rejected', message: 'SMTP delivery failed' });

    transportMocks.sendMail.mockRejectedValueOnce(Object.assign(new Error('private server detail'), {
      responseCode: 450,
      command: 'RCPT TO:<person@example.invalid>',
    }));
    await expect(delivery.deliver({
      id: 'b', kind: 'invite', recipient: 'person@example.invalid', link: 'https://app.example.invalid/#/invite?token=secret',
    })).rejects.toMatchObject({ safeCategory: 'smtp_transient', message: 'SMTP delivery failed' });

    transportMocks.sendMail.mockRejectedValueOnce(Object.assign(new Error('private server detail'), {
      responseCode: 550,
      command: 'DATA',
    }));
    await expect(delivery.deliver({
      id: 'c', kind: 'invite', recipient: 'person@example.invalid', link: 'https://app.example.invalid/#/invite?token=secret',
    })).rejects.toMatchObject({ safeCategory: 'smtp_transient' });
  });

  it('requires recipient acceptance and maps rejection results to safe errors', async () => {
    const delivery = createSmtpDelivery({ host: 'smtp.example.invalid', port: 25, from: 'noreply@example.invalid' });
    const message = {
      id: 'outbox-1', kind: 'invite' as const, recipient: 'person@example.invalid', link: 'https://app.example.invalid/#/invite?token=secret',
    };
    transportMocks.sendMail.mockResolvedValueOnce({ accepted: [], rejected: ['person@example.invalid'] });
    await expect(delivery.deliver(message)).rejects.toMatchObject({
      safeCategory: 'smtp_recipient_rejected',
      message: 'SMTP delivery failed',
    });

    transportMocks.sendMail.mockResolvedValueOnce({ accepted: [], rejected: ['person@example.invalid'] });
    await expect(delivery.deliver(message)).rejects.toMatchObject({ safeCategory: 'smtp_recipient_rejected' });

    transportMocks.sendMail.mockResolvedValueOnce({ accepted: [], rejected: [] });
    await expect(delivery.deliver(message)).rejects.toMatchObject({ safeCategory: 'smtp_transient' });
  });
});
