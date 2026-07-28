# cl-sap-udfs-ruby

Gestión de User-Defined Tables (UDTs) y User-Defined Fields (UDFs) en SAP para productos Clavisco.
Port de **CL.UDFS** (.NET).

## ¿Por qué existe?

Todos los productos Clavisco almacenan datos operativos en UDTs de SAP (tablas
personalizadas). Crear, verificar, y sincronizar estas tablas debe ser un proceso
estandarizado y declarativo — no código ad-hoc en cada producto.

Sin este submódulo, cada desarrollador escribiría su propia lógica para crear UDTs,
con riesgo de nombres inconsistentes, campos faltantes, y errores silenciosos.

## Cómo se usa (la única interfaz)

Hay **una sola forma** de correr esto: rake tasks que reciben la ruta a un
archivo JSON de conexiones. Ese JSON es un arreglo — **1 elemento si el
producto es mono-compañía, N si el cliente tiene varias compañías SAP**. No
hay un "modo simple" y un "modo multi-compañía" aparte: siempre es el mismo
comando, y lo único que cambia es cuántas entradas tiene el arreglo.

```bash
rake "sap:schema:sync[/ruta/a/connections.json]"
```

La herramienta es **agnóstica al producto**: no sabe qué es una "compañía", un
"cliente" ni un "branch". Solo lee ese JSON y corre. De dónde sale ese JSON
(a mano, generado desde una tabla `Company`, inyectado por CI/CD) es decisión
exclusiva de quien la consume — ver [El archivo de conexiones](#el-archivo-de-conexiones).

## Uso como submódulo

```bash
git submodule add git@bitbucket.org:clavisco/cl-sap-udfs-ruby.git vendor/clavisco/sap_udfs
```

Cargar las rake tasks desde el Rakefile del producto:

```ruby
# Rakefile del producto (ej. EMA)
Dir[Rails.root.join("vendor/clavisco/sap_udfs/lib/tasks/*.rake")].each { |f| load f }
```

El producto debe tener `Clavisco::ServiceLayer::Client` ya cargado (este gem
no depende de `service_layer` directamente).

## Definir un schema (JSON)

Los schemas viven en `config/sap_schemas/*.json` de cada producto consumidor.

`IsUDT` es **obligatorio** en todo schema (`true` o `false`, sin default) — así,
si alguien solo se acuerda de que "hay que ponerle `@`" y se olvida de esto,
la validación falla altiro en vez de terminar creando una UDT de más por error.
Para una **UDT** (`"IsUDT": true`), el `table_name` debe llevar el prefijo `@`
**escrito por vos** — la herramienta no lo agrega ni lo adivina, solo valida que esté:

```json
// config/sap_schemas/log_events.json
{
  "table_name": "@CL_EMA_LOG_EVENTS",
  "IsUDT": true,
  "table_description": "EMA - Log Events",
  "table_type": "bott_NoObject",
  "columns": [
    { "Name": "Event", "Description": "Nombre del evento", "Type": "db_Alpha", "SubType": "st_None", "Size": 254, "Mandatory": "tNO" },
    { "Name": "Detail", "Description": "Detalle del evento", "Type": "db_Memo", "SubType": "st_None", "Mandatory": "tNO" },
    { "Name": "CreatedDate", "Description": "Fecha de creación", "Type": "db_Date", "SubType": "st_None", "Mandatory": "tNO" }
  ]
}
```

(La UDT se crea con el nombre sin `@`, `CL_EMA_LOG_EVENTS` — SAP le agrega el
prefijo internamente. Solo las referencias posteriores, como agregar/consultar
UDFs, necesitan el `@`. Por eso el schema ya lo trae escrito así.)

Para agregar un UDF sobre una tabla **nativa** de SAP (OCRD, OITM, ORDR, ...)
en vez de crear una UDT propia, marcá el schema con `"IsUDT": false`
(obligatorio, igual que en el caso UDT) y escribí el `table_name` **sin** `@`
(es un error de validación si lo lleva). En ese caso la herramienta **no**
crea la tabla, y `table_description`/`table_type` no aplican:

```json
// config/sap_schemas/ocrd_loyalty_points.json
{
  "table_name": "OCRD",
  "IsUDT": false,
  "columns": [
    { "Name": "LoyaltyPoints", "Description": "Puntos de lealtad",
      "Type": "db_Numeric", "SubType": "st_None", "Mandatory": "tNO" }
  ]
}
```

## El archivo de conexiones

Es el único input que recibe la herramienta para saber contra qué SAP correr:
un arreglo JSON, un objeto por compañía. **1 entrada = mono-compañía. N
entradas = un cliente con N compañías.** Es el mismo arreglo, el mismo
comando, la misma validación — no cambia nada más que el tamaño.

```json
// connections.json — NUNCA se commitea (tiene credenciales reales)
[
  { "name": "ACME_PROD", "base_url": "https://sl.acme.com:50000/b1s/v1/",
    "company_db": "ACME_PROD_DB", "username": "manager", "password": "..." },
  { "name": "ACME_PROD_2", "base_url": "https://sl.acme.com:50000/b1s/v1/",
    "company_db": "ACME_PROD_DB2", "username": "manager", "password": "..." }
]
```

`name` es opcional (por defecto usa `company_db`) y solo sirve para etiquetar
resultados/errores por compañía. Cómo se arma este archivo (a mano hoy, generado
por un pipeline después) es responsabilidad de quien consume la herramienta —
acá solo se lee y se valida.

El contrato de ejemplo vive en [`config/connections.sample.json`](config/connections.sample.json)
(datos ficticios, seguro de commitear — es solo el shape). **El archivo real,
con credenciales, nunca vive en este submódulo ni se commitea en ningún repo**:
es específico de cada cliente/branch, así que corresponde al producto (su
propio `.gitignore`, o mejor aún, un secreto inyectado por el pipeline de
CI/CD al momento de build/deploy de ese branch) — no al submódulo, que es
código compartido entre clientes.

## Rake tasks

```bash
# Preview (dry-run, no escribe nada) contra todas las compañías del arreglo
rake "sap:schema:diff[/ruta/a/connections.json]"

# Aplicar contra todas las compañías del arreglo
rake "sap:schema:sync[/ruta/a/connections.json]"

# Aplicar un solo schema, contra todas las compañías del arreglo
rake "sap:schema:sync_one[log_events,/ruta/a/connections.json]"

# Chequear drift entre config/sap_schemas y el lock (no llama a SAP, no recibe connections.json)
rake sap:schema:check_lock

# Sembrar/consultar filas de prueba en una UDT (plomería; los datos los da el producto)
rake "sap:test_data:seed[/ruta/a/connections.json,/ruta/a/seed.json]"
rake "sap:test_data:query[/ruta/a/connections.json,CL_EMA_LOG_EVENTS,U_Event eq 'x']"
```

`diff`, `sync` y `sync_one` aceptan un tercer argumento opcional: la ruta donde
escribir un reporte en CSV con el resultado (una fila por compañía/schema/campo).
Si se omite, el comando se comporta igual que antes (solo imprime por consola):

```bash
rake "sap:schema:sync[/ruta/a/connections.json,/ruta/a/reporte.csv]"
```

`config/sap_schemas` se resuelve igual en todos los tasks (relativo a
`Rails.root` si existe Rails, si no relativo al directorio desde donde se corre
`rake`), overridable con `SAP_SCHEMAS_PATH`. El lock vive por defecto en
`config/sync.lock` (override con `SAP_SYNC_LOCK_PATH`).

## El lock: todo o nada

`sap:schema:sync` solo escribe/actualiza `sync.lock` si **todas** las
compañías del arreglo terminaron sin error (ni fallo de conexión, ni un schema
con `:error`). Si una compañía falla, el lock no se toca, se reporta cuál
falló, y el task termina con exit code ≠ 0 — así un pipeline nunca cree que
todo quedó sincronizado cuando en realidad una compañía se quedó atrás.

`sap:schema:check_lock` no llama a SAP: compara los archivos actuales en
`config/sap_schemas` (por contenido, no solo por nombre — cada schema se
registra con un SHA256 de su contenido) contra lo último registrado en el
lock, y reporta:

- **stale**: estaba en el lock pero ya no tiene archivo de schema (pudo quedar
  un UDT/UDF huérfano en SAP — revisar a mano).
- **pending**: tiene archivo de schema pero nunca terminó un `sync_all` 100%
  exitoso en todas las compañías.
- **changed**: se sincronizó bien antes, pero el archivo fue editado después
  (mismo nombre, contenido distinto) y todavía no se volvió a correr el sync.

## Datos de prueba (`sap:test_data:*`)

`sap:test_data:seed`/`query` son plomería de acceso a filas de una UDT (con la
convención `U_` de SAP), independiente del sync de schemas. La herramienta no
trae datos de prueba propios — el `seed.json` (qué tabla, qué filas) lo arma
el producto:

```json
// seed.json
{ "table_name": "CL_EMA_LOG_EVENTS", "rows": [ { "Event": "test", "Detail": "..." } ] }
```

## Estructura interna

```
lib/clavisco/sap_udfs/
  connections.rb           # Lee/valida el archivo de conexiones
  client_factory.rb        # connection hash → Clavisco::ServiceLayer::Client
  multi_company_sync.rb    # Orquesta: recorre el arreglo, corre schema_sync_service por cada entrada
  schema_sync_service.rb   # Motor de sync/diff contra UNA conexión — pieza interna, no se usa suelta
  lock.rb                  # sync.lock: todo-o-nada + detección de drift
  csv_report.rb            # aplana resultados de sync/diff a filas CSV
  test_data_helper.rb      # query/insert de filas en UDTs
  rake_support.rb          # Lógica detrás de las rake tasks
lib/tasks/sap_udfs.rake    # rake sap:schema:* / sap:test_data:*
```

`SchemaSyncService` es el motor que sabe construir los `get`/`post`/`patch`
contra `UserTablesMD`/`UserFieldsMD` para una sola conexión — es la pieza que
`MultiCompanySync` invoca una vez por cada entrada del arreglo. No es una
forma alternativa de usar la herramienta: la interfaz soportada es siempre
las rake tasks + el archivo de conexiones, sea de 1 o N entradas.

Los JSON schemas viven en cada producto: `config/sap_schemas/*.json`
