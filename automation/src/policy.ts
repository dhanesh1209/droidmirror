export class PolicyError extends Error {}

export interface PolicyOptions {
  /** Device serials the tool may touch. Nothing is allowed unless a serial is listed. */
  allowedSerials: string[];
  /** Taps, swipes, keys, text, app launch/stop, screenshots and the UI tree. Off by default. */
  allowControl: boolean;
  /** Returning notification text to the client. A separate switch from control. */
  allowNotificationText: boolean;
  /** Replying to and dismissing phone notifications. A separate switch from reading them. */
  allowNotificationActions?: boolean;
}

/**
 * The safety rules for automation. There are no per-action prompts (tests run hundreds of actions),
 * so the guard is: explicit opt-in flag + an explicit device allowlist. A phone that merely happens
 * to be plugged in is never touched.
 */
export class Policy {
  readonly allowedSerials: readonly string[];
  readonly allowControl: boolean;
  readonly allowNotificationText: boolean;
  readonly allowNotificationActions: boolean;

  constructor(options: PolicyOptions) {
    this.allowedSerials = [...options.allowedSerials];
    this.allowControl = options.allowControl;
    this.allowNotificationText = options.allowNotificationText;
    this.allowNotificationActions = options.allowNotificationActions ?? false;
  }

  /** Throws unless control is enabled; returns the serial to act on. */
  requireControl(requested?: string): string {
    if (!this.allowControl) {
      throw new PolicyError(
        "Device control is disabled. Start the server with --allow-control and --device <serial> " +
          "to enable taps, swipes, text, screenshots and the UI tree.",
      );
    }
    return this.resolveSerial(requested);
  }

  /** Picks the target device: the requested one if allowed, or the only allowed one. */
  resolveSerial(requested?: string): string {
    if (this.allowedSerials.length === 0) {
      throw new PolicyError("No devices are allowed. Pass --device <serial> (repeatable) or set DROIDMIRROR_DEVICES.");
    }
    if (requested !== undefined) {
      if (!this.allowedSerials.includes(requested)) {
        throw new PolicyError(`Device ${requested} is not in the allowlist (${this.allowedSerials.join(", ")}).`);
      }
      return requested;
    }
    if (this.allowedSerials.length === 1) return this.allowedSerials[0]!;
    throw new PolicyError(`Several devices are allowed (${this.allowedSerials.join(", ")}); pass \`device\` to choose one.`);
  }

  requireNotificationText(): void {
    if (!this.allowNotificationText) {
      throw new PolicyError("Reading notification text is disabled. Start the server with --allow-notification-text to enable it.");
    }
  }

  requireNotificationActions(): void {
    if (!this.allowNotificationActions) {
      throw new PolicyError("Replying to and dismissing notifications is disabled. Start the server with --allow-notification-actions to enable it.");
    }
  }

  isAllowed(serial: string): boolean {
    return this.allowedSerials.includes(serial);
  }
}
