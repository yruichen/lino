declare module 'pagedjs' {
  export class Previewer {
    on(event: 'page', listener: () => void): void;
    preview(): Promise<{ total: number }>;
  }
}
