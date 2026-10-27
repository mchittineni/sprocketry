'use client';

import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react';
import { Icon } from './Icon';

type Toast = { id: number; ok: boolean; message: string };
const ToastContext = createContext<(ok: boolean, message: string) => void>(() => {});

export const useToast = () => useContext(ToastContext);

// Short confirmations after cart actions. The region is a polite live region,
// so screen readers announce each message without moving focus.
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const next = useRef(0);

  const show = useCallback((ok: boolean, message: string) => {
    const id = ++next.current;
    setToasts((t) => [...t.slice(-2), { id, ok, message }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), ok ? 3000 : 5000);
  }, []);

  return (
    <ToastContext.Provider value={show}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.ok ? '' : 'toast-error'}`}>
            <Icon name={t.ok ? 'check' : 'alert'} size={18} />
            {t.message}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}
