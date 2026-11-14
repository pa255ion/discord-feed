// Qt view for discord-feed. See shim.h for the contract with the Zig core.
// No Q_OBJECT classes, so no moc step: signals are connected to lambdas and
// subclasses only override virtual event handlers.

#include "shim.h"

#include <QActionGroup>
#include <QApplication>
#include <QDateTime>
#include <QGraphicsOpacityEffect>
#include <QHBoxLayout>
#include <QHash>
#include <QLabel>
#include <QMenu>
#include <QMouseEvent>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPainter>
#include <QPainterPath>
#include <QPointer>
#include <QPropertyAnimation>
#include <QScreen>
#include <QScrollArea>
#include <QScrollBar>
#include <QSequentialAnimationGroup>
#include <QSizeGrip>
#include <QSocketNotifier>
#include <QSystemTrayIcon>
#include <QTimer>
#include <QVBoxLayout>

#include <optional>

namespace {

DfCallbacks g_cb;

QString qs(DfStr s) { return QString::fromUtf8(s.ptr, qsizetype(s.len)); }

const int kAvatar = 32;

QPixmap roundAvatar(const QPixmap &src) {
    const qreal dpr = qApp->devicePixelRatio();
    const int px = int(kAvatar * dpr);
    QPixmap out(px, px);
    out.fill(Qt::transparent);
    QPainter p(&out);
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::SmoothPixmapTransform);
    QPainterPath clip;
    clip.addEllipse(0, 0, px, px);
    p.setClipPath(clip);
    p.drawPixmap(0, 0, px, px, src);
    out.setDevicePixelRatio(dpr);
    return out;
}

QPixmap placeholderAvatar() {
    QPixmap px(64, 64);
    px.fill(QColor(0x5865f2));
    return roundAvatar(px);
}

// Downloads and caches avatars; labels waiting for the same URL share one request.
class AvatarCache {
public:
    void load(const QString &url, QLabel *label) {
        if (auto it = cache_.find(url); it != cache_.end()) {
            label->setPixmap(*it);
            return;
        }
        label->setPixmap(placeholderAvatar());
        if (url.isEmpty()) return;
        auto &waiting = pending_[url];
        waiting.append(label);
        if (waiting.size() > 1) return;
        QNetworkReply *reply = nam_.get(QNetworkRequest(QUrl(url)));
        QObject::connect(reply, &QNetworkReply::finished, [this, reply, url] {
            reply->deleteLater();
            QPixmap px;
            if (reply->error() == QNetworkReply::NoError) px.loadFromData(reply->readAll());
            QPixmap round = px.isNull() ? placeholderAvatar() : roundAvatar(px);
            if (!px.isNull()) cache_.insert(url, round);
            for (const QPointer<QLabel> &l : pending_.take(url))
                if (l) l->setPixmap(round);
        });
    }

private:
    QNetworkAccessManager nam_;
    QHash<QString, QPixmap> cache_;
    QHash<QString, QList<QPointer<QLabel>>> pending_;
};

class Entry : public QFrame {
public:
    Entry(uint64_t id, const QString &author, const QString &where, const QString &content,
          int64_t ts, bool mention, AvatarCache &avatars)
        : id_(id) {
        setObjectName(mention ? "entryMention" : "entry");
        setCursor(Qt::PointingHandCursor);

        auto *row = new QHBoxLayout(this);
        row->setContentsMargins(8, 6, 8, 6);
        row->setSpacing(8);

        auto *avatar = new QLabel;
        avatar->setFixedSize(kAvatar, kAvatar);
        avatar->setAlignment(Qt::AlignTop);
        row->addWidget(avatar, 0, Qt::AlignTop);
        avatarLabel_ = avatar;

        auto *col = new QVBoxLayout;
        col->setSpacing(1);
        row->addLayout(col, 1);

        QString time = QDateTime::fromMSecsSinceEpoch(ts).toString("HH:mm");
        auto *head = new QLabel(QString("<b>%1</b>&nbsp; <span style='color:#949ba4'>%2 · %3</span>")
                                    .arg(author.toHtmlEscaped(), where.toHtmlEscaped(), time));
        head->setObjectName("head");
        head->setTextFormat(Qt::RichText);
        head->setWordWrap(true);
        col->addWidget(head);

        auto *body = new QLabel(content);
        body->setObjectName("body");
        body->setTextFormat(Qt::PlainText);
        body->setWordWrap(true);
        col->addWidget(body);
        if (content.isEmpty()) body->hide();

        effect_ = new QGraphicsOpacityEffect(this);
        effect_->setOpacity(1.0);
        setGraphicsEffect(effect_);
    }

    QLabel *avatarLabel() const { return avatarLabel_; }

    void setRead() {
        if (!fading_) effect_->setOpacity(0.55);
    }

    // Fades out, collapses, then deletes itself.
    void fadeOut() {
        if (fading_) return;
        fading_ = true;
        auto *group = new QSequentialAnimationGroup(this);
        auto *fade = new QPropertyAnimation(effect_, "opacity");
        fade->setDuration(450);
        fade->setEndValue(0.0);
        group->addAnimation(fade);
        auto *collapse = new QPropertyAnimation(this, "maximumHeight");
        collapse->setDuration(180);
        collapse->setStartValue(height());
        collapse->setEndValue(0);
        group->addAnimation(collapse);
        QObject::connect(group, &QAbstractAnimation::finished, this, &QObject::deleteLater);
        group->start(QAbstractAnimation::DeleteWhenStopped);
    }

protected:
    // Accept the press so the release comes back here instead of dragging the window.
    void mousePressEvent(QMouseEvent *e) override { e->accept(); }
    void mouseReleaseEvent(QMouseEvent *e) override {
        if (fading_ || !rect().contains(e->position().toPoint())) return;
        if (e->button() == Qt::LeftButton) g_cb.entry_clicked(g_cb.ctx, id_);
        else if (e->button() == Qt::MiddleButton) g_cb.entry_dismissed(g_cb.ctx, id_);
        else return QFrame::mouseReleaseEvent(e);
    }

private:
    uint64_t id_;
    QLabel *avatarLabel_;
    QGraphicsOpacityEffect *effect_;
    bool fading_ = false;
};

const char *kStyle = R"(
QWidget { color: #dbdee1; font-size: 10pt; }
QScrollArea, #feed { background: transparent; }
#entry, #entryMention { background: rgba(255,255,255,0.04); border-radius: 6px; }
#entry:hover, #entryMention:hover { background: rgba(255,255,255,0.09); }
#entryMention { background: rgba(240,178,50,0.12); border-left: 3px solid #f0b232; }
#title { color: #949ba4; font-size: 9pt; }
#body { color: #dbdee1; }
QScrollBar:vertical { background: transparent; width: 6px; margin: 0; }
QScrollBar::handle:vertical { background: rgba(255,255,255,0.18); border-radius: 3px; min-height: 24px; }
QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page { height: 0; background: none; }
QMenu { background: #2b2d31; border: 1px solid #1e1f22; padding: 4px; }
QMenu::item { padding: 4px 18px; border-radius: 3px; }
QMenu::item:selected { background: #404249; }
QMenu::separator { height: 1px; background: #3f4147; margin: 4px 6px; }
)";

class FeedWindow : public QWidget {
public:
    FeedWindow() {
        setWindowTitle("Discord feed");
        setAttribute(Qt::WA_TranslucentBackground);
        setAttribute(Qt::WA_ShowWithoutActivating);
        setWindowFlags(baseFlags() | Qt::WindowStaysOnTopHint);
        setStyleSheet(kStyle);
        setMinimumSize(220, 140);

        auto *outer = new QVBoxLayout(this);
        outer->setContentsMargins(8, 6, 4, 4);
        outer->setSpacing(4);

        auto *header = new QHBoxLayout;
        header->setContentsMargins(4, 0, 4, 0);
        dot_ = new QLabel;
        dot_->setFixedSize(8, 8);
        header->addWidget(dot_);
        title_ = new QLabel;
        title_->setObjectName("title");
        header->addWidget(title_, 1);
        outer->addLayout(header);

        scroll_ = new QScrollArea;
        scroll_->setFrameShape(QFrame::NoFrame);
        scroll_->setWidgetResizable(true);
        scroll_->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        scroll_->viewport()->setAutoFillBackground(false);
        auto *feed = new QWidget;
        feed->setObjectName("feed");
        list_ = new QVBoxLayout(feed);
        list_->setContentsMargins(0, 0, 4, 0);
        list_->setSpacing(4);
        list_->addStretch(1); // keeps entries at the bottom, newest last
        scroll_->setWidget(feed);
        outer->addWidget(scroll_, 1);

        // Follow new messages unless the user scrolled up to read older ones.
        QScrollBar *bar = scroll_->verticalScrollBar();
        QObject::connect(bar, &QScrollBar::valueChanged, [this, bar](int v) {
            if (!adjusting_) stick_ = v >= bar->maximum() - 4;
        });
        QObject::connect(bar, &QScrollBar::rangeChanged, [this, bar](int, int max) {
            if (!stick_) return;
            adjusting_ = true;
            bar->setValue(max);
            adjusting_ = false;
        });

        auto *grip = new QSizeGrip(this);
        grip->setFixedSize(12, 12);
        outer->addWidget(grip, 0, Qt::AlignRight | Qt::AlignBottom);

        geomTimer_.setSingleShot(true);
        geomTimer_.setInterval(400);
        QObject::connect(&geomTimer_, &QTimer::timeout, [this] {
            QRect g = geometry();
            g_cb.geometry(g_cb.ctx, g.x(), g.y(), g.width(), g.height());
        });

        buildMenu();
        setStatus(false, "waiting for Vesktop");
    }

    void apply(const DfState &st) {
        opacity_ = st.opacity / 100.0;
        update();

        Qt::WindowFlags f = baseFlags();
        if (st.on_top) f |= Qt::WindowStaysOnTopHint;
        if (st.click_through && tray_) f |= Qt::WindowTransparentForInput;
        if (f != windowFlags()) {
            const bool vis = isVisible();
            const QRect g = geometry();
            setWindowFlags(f); // hides the window
            setGeometry(g);
            if (vis) show();
        }

        QSignalBlocker b1(ackGroup_), b2(decayGroup_), b3(opacityGroup_), b4(onTop_), b5(clickThrough_),
            b6(pause_);
        checkByValue(ackGroup_, st.ack_mode);
        checkByValue(decayGroup_, st.decay_s);
        checkByValue(opacityGroup_, st.opacity);
        onTop_->setChecked(st.on_top);
        clickThrough_->setChecked(st.click_through && tray_);
        pause_->setChecked(st.paused);
    }

    void add(uint64_t id, const QString &author, const QString &where, const QString &content,
             const QString &avatar, int64_t ts, bool mention) {
        auto *e = new Entry(id, author, where, content, ts, mention, avatars_);
        avatars_.load(avatar, e->avatarLabel());
        entries_.insert(id, e);
        QObject::connect(e, &QObject::destroyed, [this, id] { entries_.remove(id); });
        list_->addWidget(e);
    }

    void fade(uint64_t id) {
        if (Entry *e = entries_.value(id)) e->fadeOut();
    }
    void setRead(uint64_t id) {
        if (Entry *e = entries_.value(id)) e->setRead();
    }

    void setStatus(bool connected, const QString &text) {
        dot_->setStyleSheet(QString("background:%1; border-radius:4px;").arg(connected ? "#23a55a" : "#80848e"));
        title_->setText(text.isEmpty() ? "Discord feed" : "Discord feed · " + text);
        if (tray_) tray_->setToolTip(title_->text());
    }

    void placeDefault(int w, int h) {
        QRect avail = QGuiApplication::primaryScreen()->availableGeometry();
        setGeometry(avail.right() - w - 16, avail.top() + 16, w, h);
    }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing);
        QColor bg(0x1e, 0x1f, 0x22);
        bg.setAlphaF(opacity_);
        p.setPen(Qt::NoPen);
        p.setBrush(bg);
        p.drawRoundedRect(rect(), 10, 10);
    }

    // Drag the window by any empty area (header, gaps between entries).
    void mousePressEvent(QMouseEvent *e) override {
        if (e->button() == Qt::LeftButton) dragOffset_ = e->globalPosition().toPoint() - frameGeometry().topLeft();
    }
    void mouseMoveEvent(QMouseEvent *e) override {
        if (dragOffset_ && (e->buttons() & Qt::LeftButton)) move(e->globalPosition().toPoint() - *dragOffset_);
    }
    void mouseReleaseEvent(QMouseEvent *) override { dragOffset_.reset(); }

    void contextMenuEvent(QContextMenuEvent *e) override { menu_->popup(e->globalPos()); }
    void enterEvent(QEnterEvent *) override { g_cb.hover(g_cb.ctx, 1); }
    void leaveEvent(QEvent *) override { g_cb.hover(g_cb.ctx, 0); }
    void moveEvent(QMoveEvent *) override { if (isVisible()) geomTimer_.start(); }
    void resizeEvent(QResizeEvent *) override { if (isVisible()) geomTimer_.start(); }

private:
    static Qt::WindowFlags baseFlags() {
        return Qt::Tool | Qt::FramelessWindowHint | Qt::WindowDoesNotAcceptFocus;
    }

    static void checkByValue(QActionGroup *g, int value) {
        for (QAction *a : g->actions()) a->setChecked(a->data().toInt() == value);
    }

    QActionGroup *radio(QMenu *parent, const QString &title, int action,
                        std::initializer_list<std::pair<const char *, int>> items) {
        QMenu *sub = parent->addMenu(title);
        auto *group = new QActionGroup(sub);
        for (auto [label, value] : items) {
            QAction *a = sub->addAction(label);
            a->setCheckable(true);
            a->setData(value);
            group->addAction(a);
            QObject::connect(a, &QAction::triggered, [action, value] { g_cb.action(g_cb.ctx, action, value); });
        }
        return group;
    }

    QAction *toggle(QMenu *m, const QString &label, int action) {
        QAction *a = m->addAction(label);
        a->setCheckable(true);
        QObject::connect(a, &QAction::toggled, [action](bool on) { g_cb.action(g_cb.ctx, action, on); });
        return a;
    }

    void buildMenu() {
        menu_ = new QMenu(this);
        menu_->setStyleSheet(kStyle);
        ackGroup_ = radio(menu_, "Mark as read", DF_ACT_ACK_MODE,
                          {{"Never", 0}, {"When shown", 1}, {"When it fades", 2}});
        decayGroup_ = radio(menu_, "Fade after", DF_ACT_DECAY,
                            {{"15 seconds", 15}, {"30 seconds", 30}, {"1 minute", 60}, {"2 minutes", 120},
                             {"5 minutes", 300}, {"10 minutes", 600}, {"Never", 0}});
        opacityGroup_ = radio(menu_, "Background opacity", DF_ACT_OPACITY,
                              {{"100%", 100}, {"85%", 85}, {"70%", 70}, {"50%", 50}, {"30%", 30}, {"10%", 10}});
        menu_->addSeparator();
        pause_ = toggle(menu_, "Pause fading", DF_ACT_PAUSE);
        onTop_ = toggle(menu_, "Always on top", DF_ACT_ON_TOP);
        clickThrough_ = toggle(menu_, "Click-through (control from tray)", DF_ACT_CLICK_THROUGH);
        menu_->addSeparator();
        QObject::connect(menu_->addAction("Clear"), &QAction::triggered,
                         [] { g_cb.action(g_cb.ctx, DF_ACT_CLEAR, 0); });
        QObject::connect(menu_->addAction("Quit"), &QAction::triggered,
                         [] { g_cb.action(g_cb.ctx, DF_ACT_QUIT, 0); });

        if (QSystemTrayIcon::isSystemTrayAvailable()) {
            tray_ = new QSystemTrayIcon(trayIcon(), this);
            QMenu *trayMenu = new QMenu(this);
            trayMenu->setStyleSheet(kStyle);
            QObject::connect(trayMenu->addAction("Show / hide"), &QAction::triggered, [this] { setVisible(!isVisible()); });
            trayMenu->addSeparator();
            for (QAction *a : menu_->actions()) trayMenu->addAction(a);
            tray_->setContextMenu(trayMenu);
            QObject::connect(tray_, &QSystemTrayIcon::activated, [this](QSystemTrayIcon::ActivationReason r) {
                if (r == QSystemTrayIcon::Trigger) setVisible(!isVisible());
            });
            tray_->show();
        } else {
            clickThrough_->setEnabled(false);
            clickThrough_->setText("Click-through (needs a system tray)");
        }
    }

    static QIcon trayIcon() {
        QPixmap px(64, 64);
        px.fill(Qt::transparent);
        QPainter p(&px);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(0x5865f2));
        p.drawRoundedRect(4, 8, 56, 40, 12, 12);
        QPolygon tail({QPoint(16, 44), QPoint(30, 44), QPoint(14, 58)});
        p.drawPolygon(tail);
        p.setBrush(Qt::white);
        for (int i = 0; i < 3; ++i) p.drawRoundedRect(14, 17 + i * 9, i == 2 ? 24 : 36, 5, 2, 2);
        return QIcon(px);
    }

    double opacity_ = 0.85;
    QLabel *dot_, *title_;
    QScrollArea *scroll_;
    QVBoxLayout *list_;
    bool stick_ = true, adjusting_ = false;
    std::optional<QPoint> dragOffset_;
    QTimer geomTimer_;
    QHash<uint64_t, Entry *> entries_;
    AvatarCache avatars_;
    QMenu *menu_;
    QSystemTrayIcon *tray_ = nullptr;
    QActionGroup *ackGroup_, *decayGroup_, *opacityGroup_;
    QAction *pause_, *onTop_, *clickThrough_;
};

QApplication *g_app;
FeedWindow *g_win;
QSocketNotifier *g_notifier;
QTimer *g_tick;

} // namespace

extern "C" {

int df_init(int argc, char **argv, const DfCallbacks *cb) {
    g_cb = *cb;
    static int s_argc = argc;
    g_app = new QApplication(s_argc, argv);
    g_app->setApplicationName("discord-feed");
    g_app->setQuitOnLastWindowClosed(false);
    g_win = new FeedWindow;
    g_tick = new QTimer;
    QObject::connect(g_tick, &QTimer::timeout, [] { g_cb.tick(g_cb.ctx); });
    g_tick->start(200);
    return 0;
}

void df_set_geometry(int x, int y, int w, int h) {
    if (x < 0 || y < 0) g_win->placeDefault(w, h);
    else g_win->setGeometry(x, y, w, h);
}

void df_apply(const DfState *st) { g_win->apply(*st); }

void df_watch_fd(int fd) {
    delete g_notifier;
    g_notifier = nullptr;
    if (fd < 0) return;
    g_notifier = new QSocketNotifier(fd, QSocketNotifier::Read);
    QObject::connect(g_notifier, &QSocketNotifier::activated, [] { g_cb.readable(g_cb.ctx); });
}

void df_add(uint64_t id, DfStr author, DfStr where, DfStr content, DfStr avatar_url, int64_t ts, int mention) {
    g_win->add(id, qs(author), qs(where), qs(content), qs(avatar_url), ts, mention);
}

void df_fade(uint64_t id) { g_win->fade(id); }
void df_set_read(uint64_t id) { g_win->setRead(id); }
void df_set_status(int connected, DfStr text) { g_win->setStatus(connected, qs(text)); }

int df_exec(void) {
    g_win->show();
    return g_app->exec();
}

void df_quit(void) { g_app->quit(); }
}
