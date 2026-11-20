export class InputError extends Error {}

const PACKAGE = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

/** Android package names only: letters, digits, underscores and dots. Anything else could change the shell command. */
export function assertPackage(name: string): string {
  if (typeof name !== "string" || !PACKAGE.test(name) || name.length > 200) {
    throw new InputError(`Not a valid package name: ${JSON.stringify(String(name).slice(0, 60))}`);
  }
  return name;
}

/** A whole-number screen coordinate or duration within [min, max]. */
export function assertInt(label: string, value: unknown, min = 0, max = 100_000): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new InputError(`${label} must be a number`);
  const n = Math.round(value);
  if (n < min || n > max) throw new InputError(`${label} must be between ${min} and ${max} (got ${n})`);
  return n;
}

/** Single-quotes a string for the phone's shell. */
export function shellQuote(s: string): string {
  return "'" + s.replace(/'/g, `'\\''`) + "'";
}

/**
 * Text for `adb shell input text`: spaces become %s. Non-ASCII text and the literal sequence "%s"
 * cannot be typed this way, so they are rejected up front instead of being typed wrongly.
 */
export function toInputText(s: string): string {
  if (typeof s !== "string" || s.length === 0) throw new InputError("text must not be empty");
  if (s.length > 500) throw new InputError("text is limited to 500 characters per call");
  if (!/^[\x20-\x7e]+$/.test(s)) throw new InputError("adb input can only type printable ASCII characters");
  if (s.includes("%s")) throw new InputError("The character sequence %s cannot be typed with adb input");
  return s.replaceAll(" ", "%s");
}

/** Keys the tool may press. POWER is left out on purpose: it would lock the phone mid-test. */
export const KEYS: Readonly<Record<string, number>> = {
  HOME: 3,
  BACK: 4,
  SEARCH: 84,
  MENU: 82,
  APP_SWITCH: 187,
  ENTER: 66,
  TAB: 61,
  ESCAPE: 111,
  DELETE: 67,
  VOLUME_UP: 24,
  VOLUME_DOWN: 25,
  WAKEUP: 224,
  DPAD_UP: 19,
  DPAD_DOWN: 20,
  DPAD_LEFT: 21,
  DPAD_RIGHT: 22,
  DPAD_CENTER: 23,
};

export function keyCode(name: string): number {
  const code = KEYS[String(name).toUpperCase()];
  if (code === undefined) throw new InputError(`Unknown key ${JSON.stringify(String(name).slice(0, 40))}. Allowed: ${Object.keys(KEYS).join(", ")}`);
  return code;
}
