// DeepSeek Harness client half of the standalone vision-image-model bundle.
// Built as a prebundled CJS handoff (the dsh client module system contract):
// the script registers a factory; the loader materializes it and receives
// `apply`. The factory registers one card in the Plugins settings section.
window.__ModuleLoader__.load({
  id: "dsh-vision-image-model",
  factory: function (require) {
    var module = { exports: {} };
    var exports = module.exports;
    Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

    var ROUTE = "/vision-image-model/config";

    var TEXT = {
      en: {
        title: "Vision image model",
        subtitle: "Pick one already-configured vision model for image reads. It is used exactly, with no failover.",
        choose: "Choose an image model\u2026",
        currentBroken: "current selection (no longer available)",
        notImage: "does not declare image input",
        unknownModality: "does not declare image capabilities",
        inactiveGroups: "Configured but inactive providers (fix them in Models, then reload this card):",
        catalogError: "Model catalog failed to load:",
        save: "Save",
        saving: "saving\u2026",
        saved: "saved",
        loading: "loading\u2026",
        loadFailed: "load failed",
        saveFailed: "save failed",
        readOnly: "Settings are read-only in this deployment.",
        discard: "Discard",
        unsaved: "unsaved changes",
      },
      zh: {
        title: "图片模型（Vision）",
        subtitle: "从已配置的模型里选一个作为图片读取模型；运行时精确使用，不做故障转移。",
        choose: "选择一个图片模型\u2026",
        currentBroken: "当前选择（已失效）",
        notImage: "未声明支持图片输入",
        unknownModality: "未声明能力",
        inactiveGroups: "已配置但未激活的提供商（请到 Models 修复后重新打开本卡片）：",
        catalogError: "模型目录加载失败：",
        save: "保存",
        saving: "保存中\u2026",
        saved: "已保存",
        loading: "加载中\u2026",
        loadFailed: "加载失败",
        saveFailed: "保存失败",
        readOnly: "当前部署的设置只读。",
        discard: "放弃修改",
        unsaved: "有未保存的修改",
      },
    };

    function labels() {
      var lang = (document.documentElement.lang || navigator.language || "en").toLowerCase();
      return lang.indexOf("zh") === 0 ? TEXT.zh : TEXT.en;
    }

    function optionId(provider, model) {
      return provider + "\u0000" + model;
    }

    function parseOptionId(value) {
      var at = value.indexOf("\u0000");
      if (at < 0) return { provider: "", model: "" };
      return { provider: value.slice(0, at), model: value.slice(at + 1) };
    }

    function createCard(react) {
      var h = react.createElement;

      return function VisionImageModelCard() {
        var openState = react.useState(false);
        var summaryState = react.useState(null);
        var draftState = react.useState(null);
        var noteState = react.useState("");
        var savingState = react.useState(false);

        var open = openState[0];
        var summary = summaryState[0];
        var draft = draftState[0];
        var note = noteState[0];
        var saving = savingState[0];

        var t = labels();

        var load = react.useCallback(function (keepNote) {
          return fetch(ROUTE)
            .then(function (response) {
              return response.json().then(function (body) {
                if (!response.ok) throw new Error(body.error || t.loadFailed);
                return body;
              });
            })
            .then(function (next) {
              summaryState[1](next);
              draftState[1]({ provider: next.current.provider, model: next.current.model });
              if (keepNote !== true) noteState[1]("");
              return true;
            })
            .catch(function (error) {
              noteState[1](String(error && error.message ? error.message : error));
              return false;
            });
        }, []);

        react.useEffect(function () {
          if (open && summary === null) load();
        }, [open, summary, load]);

        var chevron = function (expanded) {
          return h(
            "svg",
            {
              width: 16,
              height: 16,
              viewBox: "0 0 16 16",
              style: {
                color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                flex: "none",
                transition: "transform .16s",
                transform: expanded ? "rotate(180deg)" : "none",
              },
            },
            h("path", {
              d: "M4 6l4 4 4-4",
              fill: "none",
              stroke: "currentColor",
              strokeWidth: 1.5,
              strokeLinecap: "round",
              strokeLinejoin: "round",
            }),
          );
        };

        var buttonStyle = function (primary, disabled) {
          return {
            appearance: "none",
            font: "inherit",
            fontSize: "13px",
            lineHeight: 1.5,
            cursor: disabled ? "default" : "pointer",
            border: primary ? "1px solid transparent" : "1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.35))",
            borderRadius: "8px",
            padding: "5px 14px",
            background: primary ? "var(--dsw-alias-label-primary, currentColor)" : "none",
            color: primary ? "var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.05))" : "var(--dsw-alias-label-secondary, inherit)",
            opacity: disabled ? 0.4 : 1,
          };
        };

        var fieldRow = function (label, control, key) {
          return h(
            "label",
            {
              key: key,
              style: {
                display: "flex",
                flexDirection: "column",
                gap: "6px",
                padding: "12px 0",
                borderTop: "1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.35))",
              },
            },
            h(
              "div",
              { style: { fontSize: "13px", color: "var(--dsw-alias-label-secondary, inherit)" } },
              label,
            ),
            control,
          );
        };

        var body = null;
        if (open) {
          if (summary === null || draft === null) {
            body = h(
              "div",
              {
                style: {
                  padding: "12px 0",
                  color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                  fontSize: "13px",
                },
              },
              note || t.loading,
            );
          } else {
            var candidates = Array.isArray(summary.candidates) ? summary.candidates : [];
            var selectable = [];
            var inactive = [];
            var catalogErrors = [];
            candidates.forEach(function (group) {
              if (group.active) {
                if (group.error) {
                  catalogErrors.push(group.name + " (" + group.provider + "): " + group.error);
                }
                group.models.forEach(function (model) {
                  selectable.push({ group: group, model: model });
                });
              } else {
                inactive.push(group);
              }
            });

            var currentValue = optionId(summary.current.provider, summary.current.model);
            var currentSelectable = selectable.some(function (entry) {
              return entry.group.provider === summary.current.provider && entry.model.id === summary.current.model;
            });

            var options = [];
            if (summary.current.provider === "" || summary.current.model === "") {
              options.push(h("option", { key: "choose", value: "" }, t.choose));
            } else if (!currentSelectable) {
              options.push(
                h(
                  "option",
                  {
                    key: "broken",
                    value: currentValue,
                    disabled: true,
                  },
                  summary.current.provider + "/" + summary.current.model + " \u2014 " + t.currentBroken,
                ),
              );
            }

            var byProvider = {};
            selectable.forEach(function (entry) {
              var list = byProvider[entry.group.provider] || (byProvider[entry.group.provider] = []);
              list.push(entry);
            });
            Object.keys(byProvider).forEach(function (provider) {
              var list = byProvider[provider];
              var groupName = list[0].group.name || provider;
              options.push(
                h(
                  "optgroup",
                  { key: provider, label: groupName + " (" + provider + ")" },
                  list.map(function (entry) {
                    var disabled = entry.model.imageInput !== true;
                    var suffix = disabled
                      ? " \u2014 " + (entry.model.imageInput === false ? t.notImage : t.unknownModality)
                      : "";
                    return h(
                      "option",
                      {
                        key: provider + "/" + entry.model.id,
                        value: optionId(provider, entry.model.id),
                        disabled: disabled,
                      },
                      entry.model.name + " (" + entry.model.id + ")" + suffix,
                    );
                  }),
                ),
              );
            });

            var dirty = draft.provider !== summary.current.provider || draft.model !== summary.current.model;
            var readOnly = summary.writable !== true;
            var disabled = !dirty || saving || readOnly;

            var select = h(
              "select",
              {
                value: optionId(draft.provider, draft.model),
                disabled: readOnly,
                onChange: function (event) {
                  var picked = parseOptionId(event.target.value);
                  if (picked.provider === "" || picked.model === "") return;
                  draftState[1](picked);
                  noteState[1]("");
                },
                style: {
                  appearance: "none",
                  width: "100%",
                  padding: "8px 12px",
                  borderRadius: "8px",
                  border: "1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.35))",
                  background: "transparent",
                  color: "inherit",
                  font: "inherit",
                  fontSize: "13px",
                },
              },
              options,
            );

            body = h(
              "div",
              null,
              fieldRow(t.choose, select, "select"),
              inactive.length === 0
                ? null
                : h(
                  "div",
                  {
                    key: "inactive",
                    style: {
                      fontSize: "12px",
                      color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                      padding: "8px 0",
                    },
                  },
                  t.inactiveGroups + " " + inactive.map(function (group) { return group.name + " (" + group.provider + ")"; }).join(", "),
                ),
              catalogErrors.length === 0
                ? null
                : h(
                  "div",
                  {
                    key: "catalog-errors",
                    style: {
                      fontSize: "12px",
                      color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                      padding: "8px 0",
                    },
                  },
                  t.catalogError + " " + catalogErrors.join("; "),
                ),
              readOnly
                ? h(
                  "div",
                  {
                    key: "readonly",
                    style: { fontSize: "13px", color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))", padding: "8px 0" },
                  },
                  t.readOnly,
                )
                : null,
              h(
                "div",
                {
                  key: "footer",
                  style: {
                    borderTop: "1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.35))",
                    display: "flex",
                    justifyContent: "flex-end",
                    alignItems: "center",
                    gap: "8px",
                    padding: "12px 0 4px",
                  },
                },
                h(
                  "span",
                  {
                    role: "status",
                    style: {
                      marginRight: "auto",
                      fontSize: "12px",
                      color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                    },
                  },
                  note || (dirty ? t.unsaved : ""),
                ),
                h(
                  "button",
                  {
                    type: "button",
                    disabled: !dirty || saving,
                    onClick: function () {
                      draftState[1]({ provider: summary.current.provider, model: summary.current.model });
                      noteState[1]("");
                    },
                    style: buttonStyle(false, !dirty || saving),
                  },
                  t.discard,
                ),
                h(
                  "button",
                  {
                    type: "button",
                    disabled: disabled,
                    onClick: function () {
                      savingState[1](true);
                      noteState[1](t.saving);
                      fetch(ROUTE, {
                        method: "POST",
                        headers: { "content-type": "application/json" },
                        body: JSON.stringify({
                          provider: draft.provider,
                          model: draft.model,
                          expectedRevision: summary.revision,
                        }),
                      })
                        .then(function (response) {
                          return response.json().then(function (body) {
                            if (!response.ok) {
                              var error = new Error(body.error || t.saveFailed);
                              error.status = response.status;
                              throw error;
                            }
                            return body;
                          });
                        })
                        .then(function () {
                          savingState[1](false);
                          return load(true);
                        })
                        .then(function (ok) {
                          if (ok === true) noteState[1](t.saved);
                        })
                        .catch(function (error) {
                          savingState[1](false);
                          if (error && error.status === 409) load();
                          else noteState[1](String(error && error.message ? error.message : error));
                        });
                    },
                    style: buttonStyle(true, disabled),
                  },
                  saving ? t.saving : t.save,
                ),
              ),
            );
          }
        }

        return h(
          "div",
          {
            style: {
              border: "1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.35))",
              background: open
                ? "var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.10))"
                : "var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.05))",
              borderRadius: "12px",
              transition: "border-color .16s, background .16s",
            },
          },
          h(
            "button",
            {
              type: "button",
              "aria-expanded": open,
              onClick: function () { openState[1](!open); },
              style: {
                appearance: "none",
                width: "100%",
                font: "inherit",
                color: "inherit",
                textAlign: "left",
                cursor: "pointer",
                background: "none",
                border: 0,
                borderRadius: "12px",
                display: "flex",
                alignItems: "center",
                gap: "12px",
                padding: "14px 16px",
              },
            },
            h(
              "div",
              { style: { flex: 1, minWidth: 0 } },
              h("div", { style: { fontSize: "14px", fontWeight: 600 } }, t.title),
              h(
                "div",
                {
                  style: {
                    color: "var(--dsw-alias-label-tertiary, rgba(127,127,127,0.8))",
                    fontSize: "13px",
                    lineHeight: 1.5,
                  },
                },
                t.subtitle,
              ),
            ),
            chevron(open),
          ),
          open ? h("div", { style: { margin: "0 16px", paddingBottom: "8px" } }, body) : null,
        );
      };
    }

    function mountCard(ctx) {
      var react;
      try {
        react = require("react");
      } catch (error) {
        console.error("[vision-image-model] settings card skipped: " + error);
        return;
      }
      var Card = createCard(react);
      ctx.slots.inject("settings.plugin.item", function* () {
        yield ctx.slots.register(
          { name: "settings.plugin.item", id: "vision-image-model", order: 40 },
          Card,
        );
      });
    }

    function apply(ctx) {
      if (typeof ctx.inject === "function") {
        ctx.inject(["slots"], function (scope) {
          // The card only exists while the host route exists; with the host
          // half off (headless, settingsCard: false) it stays absent.
          fetch(ROUTE)
            .then(function (response) {
              if (response.status === 404) return;
              mountCard(scope);
            })
            .catch(function () {});
        });
      }
    }

    exports.apply = apply;
    exports.inject = [];
    return module.exports;
  },
});
