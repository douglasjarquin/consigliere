-- Source: https://github.com/kunchenguid/grok-ship/blob/ae1f5a787e544dcec69b819370615b2fcbef0eab/skills/project-management/SKILL.md
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  crewmate_id TEXT,
  repos TEXT NOT NULL,
  source_control TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  prompt TEXT NOT NULL,
  project_id TEXT,
  repo TEXT,
  branch TEXT,
  status TEXT NOT NULL,
  gate_kind TEXT,
  gate_ref TEXT,
  result TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER
);
