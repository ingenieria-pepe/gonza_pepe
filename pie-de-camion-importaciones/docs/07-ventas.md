# Ventas

Dónde termina la fruta que entró por el Pie de Camión: el **tomador de pedidos**
que usa el vendedor en la tablet, y el **informe de ventas por artículo**.

Es la otra punta del circuito. La banana entra Color 1 (verde) por el camión y
se vende Color 4/5 (madura), así que buena parte de la lógica de acá existe para
resolver eso.

```
   PIE DE CAMIÓN ──► cámara de maduración ──► VENTA
   entra Color 1                              sale Color 4 / 5
```

---

## 1. El tomador de pedidos

El vendedor arma el pedido en la tablet y **va directo a la cola de caja del ERP
contable** (Macrosoft), como un pedido `'30'` sin facturar — indistinguible de
los que carga el tomador original. Caja los factura sin enterarse de que
vinieron de otro lado.

### El pedido

| Campo | Nota |
|---|---|
| `cliente_cod` | el cliente; `999901` = **Consumidor Final** (venta anónima: el nombre del comprador pisa el del cabezal) |
| `credito` | contado o crédito (`ENCUOTAS`), es un hint para caja |
| `deposito` | `A` = Puesto · `B` = ZAC |
| `lineas` | 1 a 200: `cod_art`, `cantidad`, `precio` **con IVA incluido** |
| `ref` | **UUID de idempotencia** por intento de envío |
| `prioritario` | nace marcado "tiene que salir YA" |
| `agregado_de` | el pedido original al que este le agrega productos |

**Un precio puede ser 0**: hay líneas de regalo y de bonificación, el sistema
viejo las tiene.

**Los topes de `cantidad` y `precio` están puestos a propósito.** Las columnas
del ERP son `numeric(10,3)` y `numeric(10,2)`; sin el tope, un número gigante
revienta el `INSERT` con un 500 de *arithmetic overflow* en vez de un 400
legible.

### Reglas de negocio

- **Un vendedor sin número asignado no puede crear pedidos.** El mapeo usuario →
  código de vendedor del ERP lo administra un admin en *Venta → Vendedores*.
- **Los descuentos (`D…`) van en un pedido aparte.** Si se mezclan con
  mercadería, el back rechaza con 400. Es como lo hace el sistema viejo siempre:
  caja los liquida distinto.
- **En un ambiente sin ERP real conectado, el envío se corta con 403.** Igual
  que en el Pie de Camión: nunca escribir desde testing.
- **El `ref` es obligatorio.** La tablet lo repite al reintentar tras un timeout
  y así el pedido no se duplica en la cola de caja.

### Pedidos AGREGADOS (encadenados)

El cliente pide algo más después de haber cerrado el pedido. Hay dos casos:

| Situación | Qué pasa |
|---|---|
| El pedido **sigue en caja** (`FACTURADO=0`) | se le agregan líneas al **mismo** pedido: sólo `INSERT` de líneas copiando nº de documento, fecha y depósito, **sin tocar el cabezal** — exactamente como lo hace el sistema nativo |
| El pedido **ya salió de caja** | se crea un pedido nuevo, normal para el ERP, pero **encadenado** al original del lado de Aloha |

> **Regla:** el encadenado apunta **siempre al pedido raíz**. Agregar sobre un
> agregado re-apunta a la raíz → un solo grupo por cliente-día, fácil de
> razonar. Expedición, el asignador, el armador y las pantallas muestran el
> vínculo.

Hay un **candado anti-borrador-viejo**: al agregar líneas se manda también el
`cliente_cod`, y el back verifica que el pedido destino sea de **ese** cliente y
de **hoy** antes de insertar nada. Sin eso, un número equivocado le mete
mercadería al pedido de otro.

### Pedidos PRIORITARIOS

El vendedor marca un pedido que tiene que salir ya. La marca **viaja por toda la
cadena**: aparece arriba de todo en la asignación (con glow), le avisa al
armador en el celular, y dispara alarma en la pantalla de entregas.

Un pedido de puros descuentos no se puede marcar prioritario — no se arma ni se
entrega.

---

## 2. Precios

### El escalonado del vendedor

Los botones −/+ mueven **de a $50**, con dos paradas:

1. **El precio base.** Si el paso lo cruzaría, primero se clava ahí. Desde 725
   con base 750, "+" va a **750**, no a 775. (Desde el base exacto sí sigue de a
   $50, si no no te podrías mover nunca.)
2. **Los límites duros: −10% / +20% del precio base.** El paso se recorta hasta
   clavarse exacto en el borde: nunca lo pasa, nunca lo saltea.

> El rango es **asimétrico a propósito**: para arriba hay más margen que para
> abajo.

Detalle fino: los límites se redondean **hacia adentro** del rango (`ceil` el
mínimo, `floor` el máximo). Con `round`, una base chica podía dar −11,8% y
dejar un precio clampeado técnicamente fuera de rango.

Código: `codigo/frontend/src/shared/venta/precios.ts` (+ su test).

### De dónde sale el precio base

`POST /venta/ultimos-precios` devuelve, por artículo:

| Campo | Qué es |
|---|---|
| `precio_lista` | el precio de lista del ERP según la lista del cliente — **es la base del −10%/+20%** |
| `precio` + `fecha` | el último precio que se le hizo **a ese cliente** |
| `precio_global` | el último precio a cualquiera (referencia / fallback) |

También hay historial de compras del cliente
(`GET /venta/clientes/{cod}/historial`) para que el vendedor tenga referencia
antes de cotizar.

---

## 3. Stock disponible — el problema del pedido que no descuenta

**El pedido `'30'` no descuenta stock**; lo descuenta la factura de caja. Entre
que un vendedor carga y que caja factura, el saldo no se mueve y **otro vendedor
puede vender la misma fruta**.

`GET /venta/stock-disponible` resuelve eso:

```
disponible = saldo de la familia (lo que informa el ERP)
           − comprometido (pedidos '30' vigentes de la familia)
```

El comprometido sale del espejo del cabezal, así que **funciona igual si el
pedido se cargó desde Aloha o desde el tomador viejo**.

Latencias reales:

| Origen del descuento | Cuánto tarda en verse |
|---|---|
| El pedido propio, sin enviar | instantáneo (el front lo resta contra el borrador) |
| El pedido de otro vendedor | ≤ 15 s (ciclo del espejo) |
| La baja real de caja | ≤ 5 min (recálculo del saldo del ERP) |

> **El disponible es por FAMILIA, no por color.** El saldo por color del ERP es
> ficción contable: la fruta entra como Color 1 y se vende madura, así que todos
> los colores de una familia comparten el mismo número.

---

## 4. Stock por color de banana — lo que el ERP no puede dar

Esto es lo más específico del negocio y probablemente lo más útil de este
módulo. El problema: **que los vendedores no sobrevendan colores que no hay.**

El ERP no puede darlo — sus saldos por color son ficción (Color 1 +690k /
Color 4 −420k). Se triangula con piezas que el sistema ya tiene:

```
disponible(color) = cajas de las cámaras que HOY están en ese color
                    (última foto: conteo cíclico o carga del pie posterior)
                  − lo vendido DESPUÉS del conteo de cada cámara
                  − comprometido (pedidos '30' abiertos de ese color)
```

### El ancla es el CONTEO, no el día

Este es el hallazgo que hace que el número cierre. Antes se restaba el vendido
del día entero, y eso **descuenta dos veces**:

- Medido sobre 14 días, el **80% de la banana se vende antes de las 7**.
- La mayoría de las cámaras se cuentan **entre las 9 y las 12** (738 conteos
  contra 243 de madrugada).
- O sea que el conteo **ya tiene descontada** la venta de la noche.

Con el método viejo, el Color 4 daba **−2.469**: la cámara 1 se contó a las
11:03 con 685 cajas, contra 3.154 vendidas antes de esa hora.

**Cada cámara se ancla en SU conteo** y aporta su parte proporcional de lo que
salió después. Una contada a las 3 AM descuenta casi todo el día; una contada a
las 11, casi nada.

### Lo que NO era el problema

Que el color cambie durante la venta. En 14 días hubo **cero** cambios de color
entre las 0 y las 7 — se concentran a las 8 y 9, después de la operativa.
Congelar el color al arrancar el día no habría arreglado nada. Vale la pena
anotarlo: era la hipótesis intuitiva y estaba equivocada.

### Reglas

- **Siempre estimativo y JAMÁS bloquea la venta.** Es un aviso, no un candado.
- **Coronel Raíz no tiene colores** (ahí la fruta está verde).
- Una venta cuyo cabezal no está en la ventana del espejo **no desaparece del
  cálculo**: se la trata como posterior a todo conteo, que es el lado prudente
   — es peor decirle al vendedor que hay de más.

Código: `codigo/backend/app/modules/venta/stock_colores.py`.

---

## 5. Venta "pasante" — saldos que son ficción

Algunos códigos **entran con un código y salen con otro**, así que su saldo no
significa nada. Son dos familias:

- **Los «(Super)»:** la misma fruta pasa a llamarse así cuando se arma el pedido
  del supermercado.
- **Los colores de banana:** entra Color 1, sale Color 4/5.

La diferencia práctica es **dónde compensan**. Los colores caen en el mismo
producto del dashboard que su Color 1, así que el grupo cierra solo (Banana
Brasil fibra: −26.756 en el Color 4 y el producto queda en −109). Los «(Super)»
no: el súper consume de todos los calibres y orígenes, y el código vive en el
grupo de uno solo.

Medido sobre el histórico completo (entró vs salió):

| Código | Producto | Entró | Salió | Ratio |
|---|---|---|---|---|
| `600248` | Palta 60 HASS (Super) | 21.338 | 72.719 | 29% |
| `981002` | Sandía (Super) | 7.526 | 139.057 | 5% |
| `010701` | Banana Ecuador (Super) | 44.637 | 128.389 | 35% |
| `120401` | Piña (Super) | 4.428 | 33.414 | 13% |
| `890202` | Arándanos (Super) | 5.786 | 15.938 | 36% |

> **No se excluyen del total**: la fruta salió de verdad y descontarla inflaría
> el stock. Lo que se hace es **avisar**, para que nadie lea la diferencia
> contra el conteo como un error de conteo.

---

## 6. El picker de productos

Grilla estilo POS: primero **familias** (por más vendidas), y dentro de cada
familia los productos por ventas. El orden sale de un ranking **fijo, no
recalculado por request** — ver `datos/ranking-ventas-por-articulo.csv`.

- El tomador vende **por color**: `010101-4` = "Banana Brasil Color 4". El
  picker de Venta pide las variantes `-N` como ítems planos; la operación (pie
  de camión, ingresos) las sigue ocultando.
- Los **descuentos** (`D…`, ej. `D01` "Dto. Bananas madera") van en una vista
  aparte, con el ícono de la fruta que descuentan.
- Los íconos y el agrupamiento por familia salen de las mismas categorías que
  usa el Pie de Camión (`datos/categorias-de-fruta.csv`).

---

## 7. Informe de Ventas por artículo

Réplica de "Estadísticas por Artículo" del ERP, vista **detallado por
comprobante**, con dos agregados que el original no trae: **filtro por cliente
con buscador** y la columna **precio por unidad** (importe con impuestos ÷
cantidad de la línea).

Lee el ERP en vivo, **solo lectura** — el espejo guarda una ventana de ~5
semanas y este informe es por período a elección, así que puede tardar unos
segundos con rangos largos.

### Las reglas del dato (validadas una por una contra un export real)

Esto es lo que hay que respetar para que los números den:

1. **Venta = `TipDoc 'V'` CON `Afecta = 1`.** Los recibos también son `'V'` y
   también escriben líneas (5.279 en 5 semanas): sin el filtro `Afecta`
   restarían importes fantasma. `Afecta` separa exactamente lo que entra a
   estadísticas (facturas, tickets, devoluciones, N.C., N.D.) de lo que no
   (recibos, rechazos, resguardos).
2. **Las anuladas afuera.**
3. **`cantidad = CantidadHaber − CantidadDebe`** — la venta registra en Haber y
   la devolución / nota de crédito en Debe.
4. Los importes llevan el signo del documento, que coincide con el de la
   cantidad.
5. **"Con impuestos" = `TotalLinea`** (= sin IVA + IVA, verificado), así
   `sin_iva + iva = importe` siempre.
6. **Moneda 1 solamente.** Mezclar pesos con dólares en una suma sería mentira;
   si el rango tiene comprobantes en otra moneda, se avisa aparte.

### Filtro "sólo pendientes"

Pendiente = factura **a crédito** cuyo total no fue cancelado por las
imputaciones que la referencian (recibos y notas de crédito llevan referencia
contra la factura). **El contado nunca está pendiente** — regla dura verificada:
se paga 100% siempre.

Optimización que importa: una imputación nunca es anterior a la factura que
paga, así que para facturas del rango alcanza con mirar pagos desde la fecha
inicial en adelante. Sin esa poda, el agregado escanea las líneas desde 2020 y
tarda **76 segundos**.

### Dos niveles de acceso

| Quién | Ve |
|---|---|
| contadora / administración / admin | todo, y baja Excel y PDF |
| cajero | vista acotada |

---

## 8. Endpoints

### `/venta`

| Método | Path | Qué hace |
|---|---|---|
| `GET` | `/venta/pedidos` | listado (con `?con_resumen=true` trae íconos y bultos) |
| `GET` | `/venta/pedidos/{nro_fact}` | detalle con líneas |
| `POST` | `/venta/pedidos` | **crear el pedido** en la cola de caja |
| `POST` | `/venta/pedidos/{nro_fact}/agregar-lineas` | agregar al pedido que sigue en caja |
| `POST` | `/venta/pedidos/{nro_fact}/prioridad` | marcar / desmarcar prioritario |
| `POST` | `/venta/pedidos/{nro_fact}/anular` | anular |
| `GET` | `/venta/clientes` | buscador de clientes |
| `POST` | `/venta/clientes` | alta mínima (sólo el nombre es obligatorio) |
| `GET` | `/venta/clientes/{cod}/historial` | compras anteriores (referencia de precio) |
| `GET` | `/venta/clientes/{cod}/pedidos-hoy` | para ofrecer "agregar productos" |
| `POST` | `/venta/ultimos-precios` | precio de lista + últimos precios |
| `GET` | `/venta/stock-disponible` | disponible por familia (saldo − comprometido) |
| `GET` | `/venta/stock-colores` | **disponible por color de banana** |
| `GET` | `/venta/escritura-config` | ¿hay ERP real conectado? |
| `GET` `PUT` | `/venta/vendedores-config` | mapeo usuario → nº de vendedor |

### `/ventas-articulos`

| Método | Path | Qué hace |
|---|---|---|
| `GET` | `/ventas-articulos` | el informe |
| `GET` | `/ventas-articulos/articulos` | buscador de artículos |
| `GET` | `/ventas-articulos/clientes` | buscador de clientes |
| `GET` | `/ventas-articulos/excel` | export |
| `GET` | `/ventas-articulos/pdf` | export |

---

## 9. Tablas

| Tabla | Migración | Para qué |
|---|---|---|
| `ext.venta_vendedor` | 0048 | usuario Aloha → código de vendedor del ERP |
| `ext.venta_envio` | 0048 | idempotencia por `ref` |
| `ext.venta_producto_ranking` | 0050 | orden del picker (fijo, se re-siembra a mano) |
| `ext.pedido_agregado` | 0062 | el encadenado al pedido raíz |
| `ext.pedido_prioridad` | 0095 | la marca de prioritario, con quién y cuándo |
| `ext.producto_cambio` | 0114 | auditoría de precios y del maestro de artículos |
| `ext.producto_escritura_envio` | 0114 | idempotencia de la escritura de precios |

> **Por qué `ext.producto_cambio` si el ERP ya audita precios:** el ERP guarda
> sólo el usuario y la fecha *sin hora*; el maestro de artículos **no tiene
> ninguna auditoría** (se pisa sin dejar rastro — si alguien renombra un
> producto, y con eso le cambia el ícono y la categoría en toda la app, hoy no
> habría forma de saber quién fue); y el espejo es una ventana que se refresca
> cada 120 s, así que lo viejo desaparece.

---

## 10. Archivos

```
codigo/backend/app/modules/venta/
  schemas.py         el contrato del pedido
  router.py          endpoints + reglas de negocio
  queries.py         SQL
  stock_colores.py   ← el disponible por color de banana

codigo/backend/app/modules/informes/
  ventas_articulos.py         el informe (SQL + Excel)
  router_ventas_articulos.py  endpoints
  excel.py                    helpers de formato

codigo/frontend/src/modules/venta/
  NuevoPedidoPage.tsx   el tomador
  PedidosPage.tsx       el listado
  VendedoresPage.tsx    el mapeo de vendedores
codigo/frontend/src/modules/ventasart/VentasArticulosPage.tsx
codigo/frontend/src/shared/venta/precios.ts   ← el escalonado −10%/+20%
```

13 archivos de test en `codigo/backend/tests/` (`test_venta_*`,
`test_stock_disponible_venta`, `test_stock_venta_pasante`,
`test_informes_ventas_articulos`, `test_pedido_prioridad`).
