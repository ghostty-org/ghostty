#include "BellPlayer.h"

#include <QAudioOutput>
#include <QMediaPlayer>
#include <QUrl>

#include "../config/Config.h"

BellPlayer::BellPlayer(QObject *parent) : QObject(parent) {}

BellPlayer::~BellPlayer() = default;

void BellPlayer::play() {
  if (m_path.isEmpty()) return;
  if (!m_player) {
    m_audio = new QAudioOutput(this);
    m_player = new QMediaPlayer(this);
    m_player->setAudioOutput(m_audio);
  }
  m_audio->setVolume(m_volume);
  // Stop first so a back-to-back bell restarts the clip from the
  // beginning. Without this, calling play() on an already-playing
  // QMediaPlayer is a no-op and rapid bells get silently swallowed.
  m_player->stop();
  m_player->setSource(QUrl::fromLocalFile(m_path));
  m_player->play();
}

void BellPlayer::refreshFromConfig() {
  m_path = config::expandedPath("bell-audio-path");
  bool volOk = false;
  const double v = config::diskValue("bell-audio-volume").toDouble(&volOk);
  m_volume = volOk ? v : 0.5;
}
