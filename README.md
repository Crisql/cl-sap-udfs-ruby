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
| Rake tasks | `sap:schema:sync`, `sap:schema:diff` — CLI para ejecutar sincronización | Manual scripts |

## Uso como submódulo

```bash
git submodule add git@bitbucket.org:clavisco/cl-sap-udfs-ruby.git vendor/clavisco/sap_udfs
```

### Definir un schema (JSON)

```json
// config/sap_schemas/log_events.json
{
  "table_name": "CL_EMA_LOG_EVENTS",
  "table_description": "EMA - Log Events",
  "table_type": "bott_NoObject",
  "columns": [
    { "Name": "Event", "Description": "Nombre del evento", "Type": "db_Alpha", "SubType": "st_None", "Size": 254, "Mandatory": "tNO" },
    { "Name": "Detail", "Description": "Detalle del evento", "Type": "db_Memo", "SubType": "st_None", "Mandatory": "tNO" },
    { "Name": "CreatedDate", "Description": "Fecha de creación", "Type": "db_Date", "SubType": "st_None", "Mandatory": "tNO" }
  ]
}
```

### Tabla nativa de SAP (OCRD, OITM, ORDR, ...)

Por defecto un schema describe una UDT (`"IsUDT": true`, o directamente sin la
clave — es el default). Para agregar un UDF sobre una tabla **nativa** de SAP en
vez de crear una UDT propia, marcá el schema con `"IsUDT": false`. En ese caso la
herramienta **no** crea la tabla ni usa el prefijo `@`, y `table_description`/
`table_type` no aplican:

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

### Sincronizar

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

### Rake tasks

```bash
rake sap:schema:diff              # Preview cambios
rake sap:schema:sync              # Aplicar todos
rake sap:schema:sync_one[log_events]  # Aplicar uno
```

## Estructura

```
lib/clavisco/sap_udfs/
  schema_sync_service.rb  # Sync engine: JSON → SAP via SL
```

Los JSON schemas viven en cada producto: `config/sap_schemas/*.json`
