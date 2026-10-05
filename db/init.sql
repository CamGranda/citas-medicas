-- Necesaria para la restricción de exclusión (no solapar citas)
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE profesional (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(100) NOT NULL,
  especialidad VARCHAR(60) NOT NULL,
  activo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE horario_profesional (
  id BIGSERIAL PRIMARY KEY,
  profesional_id BIGINT NOT NULL REFERENCES profesional(id),
  dia_semana SMALLINT NOT NULL CHECK (dia_semana BETWEEN 1 AND 7),   -- 1 = lunes
  desde TIME NOT NULL,
  hasta TIME NOT NULL CHECK (hasta > desde),
  minutos_turno INT NOT NULL CHECK (minutos_turno BETWEEN 10 AND 120)
);

CREATE TABLE bloqueo_agenda (               -- vacaciones, ausencias, feriados
  id BIGSERIAL PRIMARY KEY,
  profesional_id BIGINT NOT NULL REFERENCES profesional(id),
  desde TIMESTAMPTZ NOT NULL,
  hasta TIMESTAMPTZ NOT NULL CHECK (hasta > desde),
  motivo VARCHAR(60)
);

-- Solo lo necesario para dar la cita y avisar. SIN datos clínicos.
CREATE TABLE paciente (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(100) NOT NULL,
  documento VARCHAR(15) NOT NULL UNIQUE,
  correo VARCHAR(120),
  telefono VARCHAR(20),
  canal_preferido VARCHAR(5) NOT NULL DEFAULT 'SMS' CHECK (canal_preferido IN ('SMS','EMAIL')),
  acepta_recordatorios BOOLEAN NOT NULL DEFAULT FALSE,
  consentimiento_en TIMESTAMPTZ,            -- cuándo aceptó recibir recordatorios
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE usuario (
  id BIGSERIAL PRIMARY KEY,
  correo VARCHAR(120) NOT NULL UNIQUE,
  password_hash VARCHAR(100) NOT NULL,
  rol VARCHAR(12) NOT NULL CHECK (rol IN ('PACIENTE','PROFESIONAL','RECEPCION','ADMIN')),
  paciente_id BIGINT REFERENCES paciente(id),
  profesional_id BIGINT REFERENCES profesional(id),
  activo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE cita (
  id BIGSERIAL PRIMARY KEY,
  profesional_id BIGINT NOT NULL REFERENCES profesional(id),
  paciente_id BIGINT NOT NULL REFERENCES paciente(id),
  tipo_consulta VARCHAR(20) NOT NULL CHECK (tipo_consulta IN ('PRIMERA_CONSULTA','CONTROL','PROCEDIMIENTO_MENOR')),
  inicio TIMESTAMPTZ NOT NULL,
  fin TIMESTAMPTZ NOT NULL CHECK (fin > inicio),
  estado VARCHAR(12) NOT NULL DEFAULT 'RESERVADA'
    CHECK (estado IN ('RESERVADA','CONFIRMADA','CANCELADA','ASISTIO','AUSENTE')),
  motivo_cancelacion VARCHAR(100),          -- texto breve, sin datos clínicos
  version INT NOT NULL DEFAULT 0,           -- bloqueo optimista al modificar
  creada_por BIGINT REFERENCES usuario(id),
  creada_en TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- GARANTÍA CONTRA LA DOBLE RESERVA: la base de datos rechaza dos citas activas
  -- que se solapen para el mismo profesional, aunque dos personas reserven a la vez.
  CONSTRAINT sin_solape_profesional EXCLUDE USING gist
    (profesional_id WITH =, tstzrange(inicio, fin) WITH &&)
    WHERE (estado IN ('RESERVADA','CONFIRMADA')),

  -- Un paciente tampoco puede estar en dos citas a la misma hora
  CONSTRAINT sin_solape_paciente EXCLUDE USING gist
    (paciente_id WITH =, tstzrange(inicio, fin) WITH &&)
    WHERE (estado IN ('RESERVADA','CONFIRMADA'))
);
CREATE INDEX idx_cita_prof_inicio ON cita (profesional_id, inicio);
CREATE INDEX idx_cita_paciente ON cita (paciente_id, inicio);

-- Los recordatorios funcionan como una cola dentro de PostgreSQL
CREATE TABLE recordatorio (
  id BIGSERIAL PRIMARY KEY,
  cita_id BIGINT NOT NULL REFERENCES cita(id),
  canal VARCHAR(5) NOT NULL CHECK (canal IN ('SMS','EMAIL')),
  programado_para TIMESTAMPTZ NOT NULL,
  estado VARCHAR(10) NOT NULL DEFAULT 'PENDIENTE'
    CHECK (estado IN ('PENDIENTE','ENVIADO','ENTREGADO','FALLIDO','CANCELADO')),
  intentos INT NOT NULL DEFAULT 0,
  proximo_intento TIMESTAMPTZ NOT NULL,
  ultimo_error VARCHAR(200),
  id_mensaje_proveedor VARCHAR(80),         -- para no duplicar y para el aviso de entrega
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (cita_id, programado_para)         -- una cita no genera dos veces el mismo recordatorio
);
CREATE INDEX idx_rec_pendientes ON recordatorio (proximo_intento) WHERE estado = 'PENDIENTE';

-- Auditoría de solo inserción
CREATE TABLE auditoria (
  id BIGSERIAL PRIMARY KEY,
  correlacion_id UUID NOT NULL,
  actor_usuario_id BIGINT,
  actor_rol VARCHAR(12),
  canal VARCHAR(10) NOT NULL CHECK (canal IN ('WEB','RECEPCION','SISTEMA')),
  accion VARCHAR(40) NOT NULL,
  entidad VARCHAR(20) NOT NULL,
  entidad_id BIGINT,
  cita_id BIGINT,
  valores_anteriores JSONB,
  valores_nuevos JSONB,
  motivo VARCHAR(100),
  ip INET,
  ocurrido_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_aud_cita ON auditoria (cita_id);
CREATE INDEX idx_aud_accion_fecha ON auditoria (accion, ocurrido_en);
CREATE RULE auditoria_sin_update AS ON UPDATE TO auditoria DO INSTEAD NOTHING;
CREATE RULE auditoria_sin_delete AS ON DELETE TO auditoria DO INSTEAD NOTHING;

-- Datos de ejemplo (ficticios)
INSERT INTO profesional (nombre, especialidad) VALUES
 ('Dra. Elena Ruiz','Medicina general'), ('Dr. Marco Salas','Pediatría'), ('Dra. Lucía Vera','Odontología');
INSERT INTO horario_profesional (profesional_id, dia_semana, desde, hasta, minutos_turno)
SELECT h.pid, d, h.desde::time, h.hasta::time, h.mins
FROM (VALUES (1,'09:00','13:00',30), (2,'14:00','18:00',30), (3,'08:00','12:00',45)) AS h(pid, desde, hasta, mins)
CROSS JOIN generate_series(1,5) AS d;
INSERT INTO paciente (nombre, documento, correo, telefono, canal_preferido, acepta_recordatorios, consentimiento_en) VALUES
 ('Ana Paredes','1700000011','ana@correo.test','0990000011','EMAIL',TRUE,now()),
 ('Luis Mora','1700000022','luis@correo.test','0990000022','SMS',TRUE,now()),
 ('Rosa Vera','1700000033','rosa@correo.test','0990000033','SMS',TRUE,now()),
 ('Carlos Ibarra','1700000044','carlos@correo.test','0990000044','EMAIL',FALSE,NULL);
