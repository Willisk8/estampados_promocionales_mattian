"use client";

import { useRef, type ReactNode } from "react";

/**
 * Select que hace auto-submit del formulario al cambiar su valor, usando un
 * boton oculto con formAction (para elegir la server action del paso) y
 * formNoValidate (los pasos intermedios no deben exigir campos de otros pasos).
 * Flujo esperado: cambiar proveedor -> carga productos; cambiar producto ->
 * carga ofertas/precios. Sin clic extra.
 */
export default function SelectAutoSubmit({
  name,
  defaultValue,
  disabled,
  ariaLabel,
  action,
  className,
  children,
}: {
  name: string;
  defaultValue?: string;
  disabled?: boolean;
  ariaLabel?: string;
  action: (formData: FormData) => Promise<void>;
  className?: string;
  children: ReactNode;
}) {
  const submitterRef = useRef<HTMLButtonElement>(null);

  return (
    <>
      <select
        name={name}
        defaultValue={defaultValue}
        disabled={disabled}
        aria-label={ariaLabel}
        className={className}
        onChange={() => {
          submitterRef.current?.form?.requestSubmit(submitterRef.current);
        }}
      >
        {children}
      </select>
      <button
        ref={submitterRef}
        type="submit"
        formAction={action}
        formNoValidate
        hidden
        aria-hidden="true"
        tabIndex={-1}
      />
    </>
  );
}
