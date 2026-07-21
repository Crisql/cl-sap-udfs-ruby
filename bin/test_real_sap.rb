#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Prueba de integración contra SAP real (ver HANDOFF_SAP_UDFS.md, sección 6).
#
# Uso:
#   1. Ajustar SERVICE_LAYER_PATH abajo para que apunte al Client real
#      (el gem/submódulo `service_layer`, no incluido en este repo).
#   2. export $(grep -v '^#' ../sap-connection.env | xargs)   # o donde tengas el .env
#   3. ruby -Ilib bin/test_real_sap.rb            # diff (dry-run) solamente
#      ruby -Ilib bin/test_real_sap.rb --apply    # diff + sync (escribe en SAP)
#
# El schema de prueba (config/sap_schemas/ocrd_loyalty_points.json) agrega
# el UDF "LoyaltyPoints" a la tabla nativa OCRD, marcado con "IsUDT": false.

require "json"

# TODO: ajustar esta ruta al Client real de Clavisco::ServiceLayer.
# Ej: require_relative "../../ema/vendor/clavisco/service_layer/lib/clavisco/service_layer"
SERVICE_LAYER_PATH = ENV["SERVICE_LAYER_PATH"] ||
                      raise("Seteá SERVICE_LAYER_PATH=/ruta/a/service_layer/lib/clavisco/service_layer.rb, " \
                            "o editá este script con la ruta fija.")
require SERVICE_LAYER_PATH

require_relative "../lib/clavisco/sap_udfs"

%w[SAP_SL_URL SAP_COMPANY_DB SAP_USERNAME SAP_PASSWORD].each do |var|
  raise "Falta la variable de entorno #{var} (cargá sap-connection.env primero)" if ENV[var].to_s.empty?
end

client = Clavisco::ServiceLayer::Client.new(
  base_url:         ENV["SAP_SL_URL"],
  company_db:       ENV["SAP_COMPANY_DB"],
  username:         ENV["SAP_USERNAME"],
  password:         ENV["SAP_PASSWORD"],
  session_owner_id: ENV["SAP_SESSION_OWNER_ID"] || "udfs-test"
)

service = Clavisco::SapUdfs::SchemaSyncService.new(
  client,
  schemas_path: File.join(__dir__, "..", "config", "sap_schemas")
)

puts "=== DIFF (dry-run, no escribe en SAP) ==="
diff = service.diff("ocrd_loyalty_points")
pp diff

unless ARGV.include?("--apply")
  puts "\nSolo diff. Corré con --apply para aplicar el sync contra SAP real."
  exit
end

puts "\n=== SYNC (aplica contra SAP real) ==="
result = service.sync("ocrd_loyalty_points")
pp result

puts "\nVerificá en SAP (Service Layer o B1 Client) que el UDF 'U_LoyaltyPoints' " \
     "quede en la tabla OCRD directamente, sin prefijo '@'."
