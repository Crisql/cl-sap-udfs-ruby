# cl-sap-udfs-ruby

Gestión de User-Defined Tables (UDTs) y User-Defined Fields (UDFs) en SAP para productos Clavisco.
Port de **CL.UDFS** (.NET).

## ¿Por qué existe?

Todos los productos Clavisco almacenan datos operativos en UDTs de SAP (tablas
personalizadas). Crear, verificar, y sincronizar estas tablas debe ser un proceso
estandarizado y declarativo — no código ad-hoc en cada producto.

Sin este submódulo, cada desarrollador escribiría su propia lógica para crear UDTs,
con riesgo de nombres inconsistentes, campos faltantes, y errores silenciosos.

## ¿Qué ofrece?

| Componente | Descripción | Equivalente .NET |
|------------|-------------|------------------|
| `SchemaSyncService` | Lee JSONs declarativos, compara contra SAP, crea tablas/campos faltantes | `CL.UDFS` sync logic |
| JSON Schemas | Definición declarativa de UDTs/UDFs en archivos JSON | Config files |
| `MultiCompanySync` | Corre el sync/diff contra N compañías (un `connections.json`), aislando fallos por compañía | — |
| `Lock` | Registro de qué schemas quedaron 100% sincronizados (todo-o-nada) | — |
| `TestDataHelper` | Query/insert de filas en UDTs (plomería, sin datos propios) | — |
| Rake tasks | `sap:schema:sync`, `sap:schema:diff`, `sap:schema:sync_one`, `sap:schema:check_lock`, `sap:test_data:seed`, `sap:test_data:query` | Manual scripts |

La herramienta es **agnóstica al producto**: no sabe qué es una "compañía", un
"cliente" ni un "branch". Solo recibe los datos de conexión que necesita — de
dónde salen esos datos (una tabla `Company`, un `.env`, lo que sea) es decisión
exclusiva de quien la consume.

`SchemaSyncService` construye directamente los `get`/`post`/`patch` contra
`UserTablesMD`/`UserFieldsMD` — el `Client` de `cl-sap-servicelayer-ruby` es un
driver puro (sin métodos `create_udt`/`create_udf`/etc.), así que toda la
convención de nombres de SAP (el `@` de las UDTs) vive únicamente acá.

## Uso como submódulo

```bash
git submodule add git@bitbucket.org:clavisco/cl-sap-udfs-ruby.git vendor/clavisco/sap_udfs
```

### Definir un schema (JSON)

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

### Tabla nativa de SAP (OCRD, OITM, ORDR, ...)

Para agregar un UDF sobre una tabla **nativa** de SAP en vez de crear una UDT
propia, marcá el schema con `"IsUDT": false` (obligatorio, igual que en el caso
UDT) y escribí el `table_name` **sin** `@` (es un error de validación si lo
lleva). En ese caso la herramienta **no**
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

### Sincronizar (una sola conexión, uso directo en Ruby)

```ruby
client = Clavisco::ServiceLayer::Client.new(...)
service = Clavisco::SapUdfs::SchemaSyncService.new(client)

# Dry-run
service.diff_all  # → muestra qué se crearía

# Aplicar
service.sync_all  # → crea tablas/campos faltantes

# Una sola tabla
service.sync("log_events")
```

### Multi-compañía: el archivo de conexiones

Un mismo cliente puede tener varias bases de datos (compañías SAP) para el
mismo producto. Las rake tasks no reciben un `Client` ya armado ni saben nada
de "cliente" o "compañía" — reciben la **ruta a un JSON** con un arreglo de
conexiones, uno por compañía a verificar (1 elemento si es mono-compañía):

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

### Rake tasks

Hay que cargar las tasks del submódulo desde el Rakefile del producto:

```ruby
# Rakefile del producto (ej. EMA)
Dir[Rails.root.join("vendor/clavisco/sap_udfs/lib/tasks/*.rake")].each { |f| load f }
```

El producto debe tener `Clavisco::ServiceLayer::Client` ya cargado (este gem
no depende de `service_layer` directamente).

```bash
# Preview (dry-run, no escribe nada)
rake "sap:schema:diff[/ruta/a/connections.json]"

# Aplicar contra todas las compañías del arreglo
rake "sap:schema:sync[/ruta/a/connections.json]"

# Aplicar un solo schema
rake "sap:schema:sync_one[log_events,/ruta/a/connections.json]"

# Chequear drift entre config/sap_schemas y el lock (no llama a SAP)
rake sap:schema:check_lock

# Sembrar/consultar filas de prueba en una UDT (plomería; los datos los da el producto)
rake "sap:test_data:seed[/ruta/a/connections.json,/ruta/a/seed.json]"
rake "sap:test_data:query[/ruta/a/connections.json,CL_EMA_LOG_EVENTS,U_Event eq 'x']"
```

`config/sap_schemas` se resuelve igual que en `SchemaSyncService` (relativo a
`Rails.root` si existe Rails, si no relativo al directorio desde donde se corre
`rake`), overridable con `SAP_SCHEMAS_PATH`. El lock vive por defecto en
`config/sync.lock` (override con `SAP_SYNC_LOCK_PATH`).

### El lock: todo o nada

`sap:schema:sync` solo escribe/actualiza `sync.lock` si **todas** las
compañías del arreglo terminaron sin error (ni fallo de conexión, ni un schema
con `:error`). Si una compañía falla, el lock no se toca, se reporta cuál
falló, y el task termina con exit code ≠ 0 — así un pipeline nunca cree que
todo quedó sincronizado cuando en realidad una compañía se quedó atrás.

`sap:schema:check_lock` no llama a SAP: compara los archivos actuales en
`config/sap_schemas` contra lo último registrado en el lock, y reporta:

- **stale**: estaba en el lock pero ya no tiene archivo de schema (pudo quedar
  un UDT/UDF huérfano en SAP — revisar a mano).
- **pending**: tiene archivo de schema pero nunca terminó un `sync_all` 100%
  exitoso en todas las compañías.

### Datos de prueba (`sap:test_data:*`)

`sap:test_data:seed`/`query` son plomería de acceso a filas de una UDT (con la
convención `U_` de SAP), independiente del sync de schemas. La herramienta no
trae datos de prueba propios — el `seed.json` (qué tabla, qué filas) lo arma
el producto:

```json
// seed.json
{ "table_name": "CL_EMA_LOG_EVENTS", "rows": [ { "Event": "test", "Detail": "..." } ] }
```

## Estructura

```
lib/clavisco/sap_udfs/
  schema_sync_service.rb   # Sync engine: JSON → SAP via SL (una conexión)
  connections.rb           # Lee/valida el archivo de conexiones
  client_factory.rb        # connection hash → Clavisco::ServiceLayer::Client
  multi_company_sync.rb    # Corre SchemaSyncService contra N conexiones
  lock.rb                  # sync.lock: todo-o-nada + detección de drift
  test_data_helper.rb      # query/insert de filas en UDTs
  rake_support.rb          # Lógica detrás de las rake tasks
lib/tasks/sap_udfs.rake    # rake sap:schema:* / sap:test_data:*
```

Los JSON schemas viven en cada producto: `config/sap_schemas/*.json`
