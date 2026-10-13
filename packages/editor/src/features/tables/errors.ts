export type TableErrorCode = 'invalidStructure' | 'invalidCell' | 'singleLine' | 'stale' | 'selectCell' | 'nested' | 'headerRow' | 'lastColumn' | 'rowBoundary' | 'columnBoundary' | 'limit' | 'insertContext';
export class TableError extends Error {
  readonly code: TableErrorCode;
  constructor(code: TableErrorCode) { super(code); this.code = code; }
}
