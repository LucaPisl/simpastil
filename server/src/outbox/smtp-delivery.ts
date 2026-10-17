import nodemailer from 'nodemailer';

export type RecoveryMessageKind = 'password-reset' | 'invite';

export interface SmtpConfig {
  host: string;
  port: number;
  user?: string;
  password?: string;
  from: string;
}

export interface OutgoingRecoveryMessage {
  id: string;
  kind: RecoveryMessageKind;
  recipient: string;
  link: string;
}

export interface OutboxDelivery {
  deliver(message: OutgoingRecoveryMessage): Promise<void>;
  close(): void;
}

export type SmtpFailureCategory = 'smtp_recipient_rejected' | 'smtp_transient';

export class SmtpDeliveryError extends Error {
  constructor(readonly safeCategory: SmtpFailureCategory) {
    super('SMTP delivery failed');
    this.name = 'SmtpDeliveryError';
  }
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => {
    switch (character) {
      case '&': return '&amp;';
      case '<': return '&lt;';
      case '>': return '&gt;';
      case '"': return '&quot;';
      default: return '&#39;';
    }
  });
}

function template(message: OutgoingRecoveryMessage): { subject: string; text: string; html: string } {
  const safeLink = escapeHtml(message.link);
  if (message.kind === 'password-reset') {
    return {
      subject: 'Reset your Simpastil password',
      text: `A password reset was requested for your Simpastil account. Open this link to choose a new password:\n\n${message.link}\n\nIf you did not request this, you can ignore this email.`,
      html: `<p>A password reset was requested for your Simpastil account.</p><p><a href="${safeLink}">Choose a new password</a></p><p>If you did not request this, you can ignore this email.</p>`,
    };
  }
  return {
    subject: 'Your Simpastil invitation',
    text: `You have been invited to join Simpastil. Open this link to continue setup:\n\n${message.link}\n\nThis one-time invitation expires automatically.`,
    html: `<p>You have been invited to join Simpastil.</p><p><a href="${safeLink}">Continue setup</a></p><p>This one-time invitation expires automatically.</p>`,
  };
}

function isPermanentRecipientRejection(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const value = error as { responseCode?: unknown; command?: unknown };
  return typeof value.responseCode === 'number'
    && value.responseCode >= 500
    && value.responseCode < 600
    && typeof value.command === 'string'
    && /RCPT\s+TO/i.test(value.command);
}

function includesRecipient(addresses: unknown, recipient: string): boolean {
  if (!Array.isArray(addresses)) return false;
  return addresses.some((address) => {
    const value = typeof address === 'string'
      ? address
      : typeof address === 'object' && address !== null && 'address' in address
        ? (address as { address?: unknown }).address
        : undefined;
    return typeof value === 'string' && value.toLowerCase() === recipient.toLowerCase();
  });
}

export function createSmtpDelivery(config: SmtpConfig): OutboxDelivery {
  const transport = nodemailer.createTransport({
    host: config.host,
    port: config.port,
    secure: config.port === 465,
    requireTLS: config.port !== 465,
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 20_000,
    tls: { minVersion: 'TLSv1.2' },
    ...(config.user && config.password
      ? { auth: { user: config.user, pass: config.password } }
      : {}),
  });

  return {
    async deliver(message): Promise<void> {
      const content = template(message);
      try {
        const result = await transport.sendMail({
          from: config.from,
          to: message.recipient,
          subject: content.subject,
          text: content.text,
          html: content.html,
          // SMTP is at-least-once; a stable Message-ID helps operators and mail
          // systems recognize a retry of the same outbox record.
          messageId: `<${message.id}@outbox.simpastil.invalid>`,
        });
        if (includesRecipient(result.accepted, message.recipient)) return;
        throw new SmtpDeliveryError(
          includesRecipient(result.rejected, message.recipient)
            ? 'smtp_recipient_rejected'
            : 'smtp_transient',
        );
      } catch (error) {
        if (error instanceof SmtpDeliveryError) throw error;
        throw new SmtpDeliveryError(
          isPermanentRecipientRejection(error)
            ? 'smtp_recipient_rejected'
            : 'smtp_transient',
        );
      }
    },
    close(): void {
      transport.close();
    },
  };
}
