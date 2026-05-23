#pragma once

#include <QObject>
#include <QString>

class QAudioOutput;
class QMediaPlayer;

// Per-window audio bell. Owns a QMediaPlayer + QAudioOutput pair and
// caches the bell-audio-path / -volume values so the bell hot path
// doesn't re-scan the on-disk config on every ring. Built lazily on
// first play() — no QMediaPlayer is allocated until a bell actually
// fires, matching the prior MainWindow behaviour.
//
// Parented to the owning window so it dies with it. Each window
// keeps its own player so KWin can route per-window audio
// independently if the user wires that up.
class BellPlayer : public QObject {
  Q_OBJECT
public:
  explicit BellPlayer(QObject *parent);
  ~BellPlayer() override;

  // Play the configured clip, restarting from the beginning if a
  // previous play is still in flight. No-op if no clip is
  // configured. The audio output volume is whatever
  // refreshFromConfig last cached.
  void play();

  // Re-read bell-audio-path / bell-audio-volume from the on-disk
  // config and update the cache. Called from
  // applyWindowConfig (init + reload).
  void refreshFromConfig();

private:
  QString m_path;
  double m_volume = 0.5;
  QMediaPlayer *m_player = nullptr;
  QAudioOutput *m_audio = nullptr;
};
