import { catalog } from './catalog.ts';

export type Locale = 'en' | 'zh-Hans';
export type MessageKey = keyof typeof catalog;
type Slots<T extends string> = T extends `${string}{${infer Key}}${infer Rest}` ? Key | Slots<Rest> : never;
export type MessageArguments<K extends MessageKey> = [Slots<typeof catalog[K][0]>] extends [never]
  ? [] : [parameters: Record<Slots<typeof catalog[K][0]>, string | number>];
const listeners = new Set<(locale: Locale) => void>();
const localizedErrors = new WeakSet<Error>();
const numberFormats = { en: new Intl.NumberFormat('en'), 'zh-Hans': new Intl.NumberFormat('zh-Hans') };
export function formatNumber(language: Locale, value: number): string { return numberFormats[language].format(value); }
export function normalizeLocale(value: unknown): Locale { return value === 'zh-Hans' ? value : 'en'; }
let locale = normalizeLocale(typeof window === 'undefined' ? undefined
  : (window as Window & { __openTyporaLocale?: unknown }).__openTyporaLocale);
export function currentLocale(): Locale { return locale; }
export function setLocale(value: unknown): Locale {
  const next = normalizeLocale(value);
  if (typeof document !== 'undefined') document.documentElement.lang = next;
  if (next !== locale) { locale = next; for (const listener of listeners) listener(next); }
  return next;
}
export function onLocaleChange(listener: (locale: Locale) => void): () => void {
  listeners.add(listener); return () => listeners.delete(listener);
}
export function tFor<K extends MessageKey>(language: Locale, key: K, ...args: MessageArguments<K>): string {
  const pair = catalog[key];
  // Runtime guards also cover stale callers; a missing key or parameter remains
  // identifiable instead of displaying undefined or silently removing content.
  const template: string = pair?.[language === 'zh-Hans' ? 1 : 0] || pair?.[0] || key;
  const parameters = args[0] as Record<string, string | number> | undefined;
  return template.replace(/\{([^}]+)\}/g, (token, name: string) => {
    if (!parameters || !Object.hasOwn(parameters, name)) return token;
    const value = parameters[name];
    return typeof value === 'number' ? formatNumber(language, value) : value;
  });
}
export function t<K extends MessageKey>(key: K, ...args: MessageArguments<K>): string { return tFor(locale, key, ...args); }
export function localizeMessage<E extends Error>(error: E, render: () => string): E {
  Object.defineProperty(error, 'message', { configurable: true, get: render });
  localizedErrors.add(error);
  return error;
}
export function localizeError<E extends Error, K extends MessageKey>(error: E, key: K, ...args: MessageArguments<K>): E {
  return localizeMessage(error, () => t(key, ...args));
}
export function isLocalizedError(error: Error): boolean { return localizedErrors.has(error); }
