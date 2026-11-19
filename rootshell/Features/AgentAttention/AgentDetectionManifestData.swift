//
//  AgentDetectionManifestData.swift
//  rootshell
//
//  Hand-maintained bundled agent-detection rules. Edit this file directly
//  and validate changes with tests/agent-attention and the detection replay
//  harness. The initial rules were derived from herdr's agent manifests
//  (https://github.com/ogulcancelik/herdr, Apache-2.0).
//

/// Bundled agent-detection manifest as JSON. Embedded as source so bundle
/// packaging can never silently drop it.
nonisolated enum AgentDetectionManifestData {
    static let json: String = #"""
    {
      "version": 2,
      "snapshotRows": 40,
      "agents": [
        {
          "id": "agy",
          "displayName": "Antigravity CLI",
          "identity": {
            "programStatusApps": [
              "antigravity"
            ],
            "screenSignatures": [
              {
                "regex": [
                  "(?i)\\bantigravity\\b"
                ],
                "not": [
                  {
                    "contains": [
                      "z.ai",
                      "kimi code"
                    ]
                  },
                  {
                    "contains": [
                      "select provider to login:"
                    ]
                  }
                ],
                "altScreenOnly": true
              },
              {
                "lineRegex": [
                  "(?i)^[\\s\\u{2580}-\\u{259F}]*[\\u{2580}-\\u{259F}][\\s\\u{2580}-\\u{259F}]*\\bantigravity cli\\b"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "contains": [
                  "? for shortcuts"
                ],
                "lineRegex": [
                  "^\\s*>(\\s|$)"
                ],
                "not": [
                  {
                    "lineRegex": [
                      "^\\s*❯"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*[│┃]\\s*>(\\s|$)"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "lineRegex": [
                  "^\\s*>(\\s|$)",
                  "^\\s*\\S.*\\s·\\s.+\\s·\\s\\S+\\s*$"
                ],
                "not": [
                  {
                    "lineRegex": [
                      "^\\s*❯"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*›"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*[│┃]\\s*>(\\s|$)"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "lineRegex": [
                  "^\\s*>(\\s|$)",
                  "^\\s*─{20,}\\s*$"
                ],
                "not": [
                  {
                    "lineRegex": [
                      "^\\s*❯"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*›"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*[│┃]\\s*>(\\s|$)"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "contains": [
                  "welcome to the antigravity cli"
                ],
                "lineRegex": [
                  "^[\\s\\u{2580}-\\u{259F}]*[\\u{2580}-\\u{259F}][\\s\\u{2580}-\\u{259F}]*$"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "contains": [
                  "requesting permission for:"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "any": [
                  {
                    "contains": [
                      "y/n approve/reject"
                    ]
                  },
                  {
                    "contains": [
                      "shift+a approve all"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              }
            ],
            "commands": [
              "agy",
              "antigravity",
              "antigravity-cli"
            ]
          },
          "rules": [
            {
              "id": "permission_prompt",
              "state": "blocked",
              "priority": 300,
              "region": "whole_recent",
              "visibleBlocker": true,
              "contains": [
                "requesting permission for:"
              ],
              "any": [
                {
                  "contains": [
                    "do you want to proceed?"
                  ]
                },
                {
                  "contains": [
                    "tab amend",
                    "edit command"
                  ]
                }
              ]
            },
            {
              "id": "spinner_working",
              "state": "working",
              "priority": 100,
              "region": "whole_recent",
              "visibleWorking": true,
              "lineRegex": [
                "^\\s*[\\u{2800}-\\u{28FF}]+\\s+\\p{Alphabetic}+\\w*ing\\b"
              ]
            },
            {
              "id": "background_tasks_working",
              "state": "working",
              "priority": 90,
              "region": "bottom_non_empty_lines(5)",
              "visibleWorking": true,
              "lineRegex": [
                "(?i)·\\s*[1-9][0-9]*\\s+task"
              ]
            },
            {
              "id": "cancel_hint_working_local",
              "state": "working",
              "priority": 95,
              "region": "bottom_non_empty_lines(6)",
              "visibleWorking": true,
              "contains": [
                "esc to cancel"
              ],
              "not": [
                {
                  "contains": [
                    "? for shortcuts"
                  ]
                },
                {
                  "contains": [
                    "↑/↓ navigate",
                    "tab complete"
                  ]
                }
              ]
            },
            {
              "id": "approval_tray_blocked_local",
              "state": "blocked",
              "priority": 500,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "contains": [
                "action required"
              ],
              "any": [
                {
                  "contains": [
                    "y/n approve/reject"
                  ]
                },
                {
                  "contains": [
                    "shift+a approve all"
                  ]
                },
                {
                  "regex": [
                    "(?im)^\\s*›.*\\bapprove\\b.*\\breject\\b"
                  ]
                }
              ]
            },
            {
              "id": "composer_idle_local",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(8)",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*>(\\s|$)"
              ],
              "any": [
                {
                  "contains": [
                    "? for shortcuts"
                  ]
                },
                {
                  "contains": [
                    "↑/↓ navigate",
                    "tab complete"
                  ]
                }
              ],
              "not": [
                {
                  "lineRegex": [
                    "^\\s*❯"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*›"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*[│┃]\\s*>(\\s|$)"
                  ]
                }
              ]
            }
          ]
        },
        {
          "id": "claude",
          "displayName": "Claude Code",
          "identity": {
            "programStatusApps": [
              "claude-code"
            ],
            "titlePatterns": [
              "^\\u{2733} "
            ],
            "screenSignatures": [
              {
                "contains": [
                  "esc to interrupt"
                ],
                "regex": [
                  "[✢✳✶✻✽]"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "lineRegex": [
                  "(?i)\\d+s [·•] ?[↑↓] ?[\\d.,]+k? tokens"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "lineRegex": [
                  "(?i)^\\s*[·✢✳✶✻✽]\\s+waiting for \\d"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "contains": [
                  "do you want to proceed?",
                  "tell claude"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "contains": [
                  "do you want to make this edit"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "contains": [
                  "tell claude what to change"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "contains": [
                  "shift+tab to approve"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "contains": [
                  "chat about this"
                ],
                "any": [
                  {
                    "contains": [
                      "enter to select"
                    ]
                  },
                  {
                    "contains": [
                      "to add notes"
                    ]
                  },
                  {
                    "contains": [
                      "to navigate"
                    ]
                  },
                  {
                    "contains": [
                      "esc to cancel"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "ready to submit your answers?"
                ],
                "any": [
                  {
                    "contains": [
                      "review your answers"
                    ]
                  },
                  {
                    "contains": [
                      "submit answers"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "esc to cancel",
                  "tab to amend"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "all": [
                  {
                    "any": [
                      {
                        "lineRegex": [
                          "^\\s*\\? for shortcuts"
                        ]
                      },
                      {
                        "regex": [
                          "(?i)●\\s+\\S+\\s+·\\s+/effort\\b"
                        ]
                      },
                      {
                        "lineRegex": [
                          "(?i)^\\s*(?:[│┃]\\s*)?[⏵⏸⏯]+\\s.*shift\\+tab to cycle"
                        ]
                      },
                      {
                        "contains": [
                          "bypassing permissions"
                        ]
                      },
                      {
                        "contains": [
                          "auto mode on"
                        ]
                      },
                      {
                        "contains": [
                          "accept edits on"
                        ]
                      },
                      {
                        "contains": [
                          "plan mode on"
                        ]
                      }
                    ]
                  }
                ],
                "any": [
                  {
                    "lineRegex": [
                      "^\\s*❯(\\s|$)"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*[│┃]\\s*>(\\s|$)"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "lineRegex": [
                  "^\\s*⏵⏵\\s+\\S"
                ],
                "region": "bottom_non_empty_lines(14)"
              },
              {
                "contains": [
                  "bypassing permissions"
                ],
                "region": "bottom_non_empty_lines(14)"
              }
            ],
            "commands": [
              "claude",
              "claude-code"
            ]
          },
          "rules": [
            {
              "id": "osc_title_working",
              "state": "working",
              "priority": 1100,
              "region": "osc_title",
              "visibleWorking": true,
              "regex": [
                "^[\\u{2800}-\\u{28FF}◐◓◑◒] "
              ]
            },
            {
              "id": "btw_overlay_working",
              "state": "working",
              "priority": 975,
              "region": "bottom_non_empty_lines(5)",
              "visibleWorking": true,
              "lineRegex": [
                "^\\s*/btw(?:\\s|$)",
                "(?i)esc to close\\s*$"
              ]
            },
            {
              "id": "transcript_viewer",
              "state": "unknown",
              "priority": 1000,
              "region": "bottom_non_empty_lines(3)",
              "skipStateUpdate": true,
              "contains": [
                "showing detailed transcript"
              ],
              "any": [
                {
                  "contains": [
                    "ctrl+o",
                    "to toggle"
                  ]
                },
                {
                  "contains": [
                    "ctrl+e",
                    "show all"
                  ]
                },
                {
                  "contains": [
                    "ctrl+e",
                    "collapse"
                  ]
                },
                {
                  "contains": [
                    "↑↓ scroll"
                  ]
                },
                {
                  "contains": [
                    "? for shortcuts"
                  ]
                }
              ]
            },
            {
              "id": "live_blocked_form",
              "state": "blocked",
              "priority": 980,
              "region": "after_last_horizontal_rule",
              "visibleBlocker": true,
              "contains": [
                "enter to select",
                "esc to cancel"
              ],
              "any": [
                {
                  "contains": [
                    "tab/arrow keys to navigate"
                  ]
                },
                {
                  "contains": [
                    "arrow keys to navigate"
                  ]
                },
                {
                  "contains": [
                    "arrows to navigate"
                  ]
                },
                {
                  "contains": [
                    "↑/↓ to navigate"
                  ]
                },
                {
                  "contains": [
                    "↑↓ to navigate"
                  ]
                }
              ]
            },
            {
              "id": "dynamic_workflow_prompt",
              "state": "blocked",
              "priority": 980,
              "region": "whole_recent",
              "visibleBlocker": true,
              "contains": [
                "run a dynamic workflow?",
                "esc to cancel"
              ]
            },
            {
              "id": "live_prompt_box",
              "state": "idle",
              "priority": 950,
              "region": "prompt_box_body",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*❯"
              ],
              "not": [
                {
                  "contains": [
                    "enter to select"
                  ]
                },
                {
                  "contains": [
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "tab/arrow keys"
                  ]
                },
                {
                  "contains": [
                    "arrow keys to navigate"
                  ]
                },
                {
                  "contains": [
                    "↑/↓ to navigate"
                  ]
                }
              ]
            },
            {
              "id": "model_picker_menu",
              "state": "unknown",
              "priority": 900,
              "region": "whole_recent",
              "skipStateUpdate": true,
              "contains": [
                "select model",
                "enter to set as default",
                "esc to cancel"
              ],
              "not": [
                {
                  "contains": [
                    "do you want to proceed?"
                  ]
                },
                {
                  "contains": [
                    "enter to select"
                  ]
                }
              ]
            },
            {
              "id": "bash_permission_prompt",
              "state": "blocked",
              "priority": 850,
              "region": "whole_recent",
              "visibleBlocker": true,
              "contains": [
                "do you want to proceed?"
              ],
              "all": [
                {
                  "any": [
                    {
                      "lineRegex": [
                        "(?i)^\\s*❯?\\s*yes\\b"
                      ]
                    },
                    {
                      "lineRegex": [
                        "(?i)^\\s*1\\.\\s*yes\\b"
                      ]
                    },
                    {
                      "lineRegex": [
                        "(?i)^\\s*2\\.\\s*no\\b"
                      ]
                    }
                  ]
                }
              ],
              "any": [
                {
                  "contains": [
                    "bash command"
                  ]
                },
                {
                  "contains": [
                    "bash("
                  ]
                },
                {
                  "contains": [
                    "contains expansion"
                  ]
                },
                {
                  "contains": [
                    "tab to amend"
                  ]
                },
                {
                  "contains": [
                    "ctrl+e to explain"
                  ]
                }
              ]
            },
            {
              "id": "generic_permission_prompt",
              "state": "blocked",
              "priority": 840,
              "region": "after_last_horizontal_rule",
              "visibleBlocker": true,
              "contains": [
                "do you want to proceed?",
                "esc to cancel"
              ],
              "all": [
                {
                  "any": [
                    {
                      "lineRegex": [
                        "(?i)^\\s*❯?\\s*1\\.\\s*yes\\b"
                      ]
                    },
                    {
                      "lineRegex": [
                        "(?i)^\\s*2\\.\\s*yes\\b"
                      ]
                    },
                    {
                      "lineRegex": [
                        "(?i)^\\s*2\\.\\s*no\\b"
                      ]
                    },
                    {
                      "lineRegex": [
                        "(?i)^\\s*3\\.\\s*no\\b"
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "id": "legacy_no_prompt_blocker",
              "state": "blocked",
              "priority": 300,
              "region": "whole_recent",
              "any": [
                {
                  "contains": [
                    "do you want to"
                  ],
                  "any": [
                    {
                      "contains": [
                        "yes"
                      ]
                    },
                    {
                      "contains": [
                        "❯"
                      ]
                    }
                  ]
                },
                {
                  "contains": [
                    "would you like to"
                  ],
                  "any": [
                    {
                      "contains": [
                        "yes"
                      ]
                    },
                    {
                      "contains": [
                        "❯"
                      ]
                    }
                  ]
                },
                {
                  "contains": [
                    "waiting for permission"
                  ]
                },
                {
                  "contains": [
                    "do you want to allow this connection?"
                  ]
                },
                {
                  "contains": [
                    "tab to amend"
                  ]
                },
                {
                  "contains": [
                    "ctrl+e to explain"
                  ]
                },
                {
                  "contains": [
                    "do you want to proceed?",
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "review your answers"
                  ]
                },
                {
                  "contains": [
                    "skip interview and plan immediately"
                  ]
                }
              ],
              "not": [
                {
                  "regex": [
                    "(?m)^\\s*❯\\s*$"
                  ]
                }
              ]
            },
            {
              "id": "osc_title_idle",
              "state": "idle",
              "priority": 250,
              "region": "osc_title",
              "visibleIdle": true,
              "regex": [
                "^\\u{2733} "
              ]
            },
            {
              "id": "osc_progress_idle",
              "state": "idle",
              "priority": 250,
              "region": "osc_progress",
              "regex": [
                "^4;0"
              ]
            },
            {
              "id": "dialog_blocked_local",
              "state": "blocked",
              "priority": 970,
              "region": "bottom_non_empty_lines(14)",
              "visibleBlocker": true,
              "any": [
                {
                  "contains": [
                    "do you want to"
                  ],
                  "regex": [
                    "(?im)^\\s*❯\\s*\\d+\\.\\s"
                  ]
                },
                {
                  "contains": [
                    "would you like to"
                  ],
                  "regex": [
                    "(?im)^\\s*❯\\s*\\d+\\.\\s"
                  ]
                },
                {
                  "contains": [
                    "shift+tab to approve"
                  ]
                },
                {
                  "contains": [
                    "esc to cancel",
                    "tab to amend"
                  ]
                },
                {
                  "contains": [
                    "ready to submit your answers?"
                  ],
                  "any": [
                    {
                      "contains": [
                        "review your answers"
                      ]
                    },
                    {
                      "contains": [
                        "submit answers"
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "id": "question_form_blocked_local",
              "state": "blocked",
              "priority": 972,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "contains": [
                "enter to select"
              ],
              "any": [
                {
                  "contains": [
                    "chat about this"
                  ]
                },
                {
                  "contains": [
                    "to add notes"
                  ]
                },
                {
                  "contains": [
                    "to switch questions"
                  ]
                }
              ]
            },
            {
              "id": "background_agents_working_local",
              "state": "working",
              "priority": 962,
              "region": "last_block_above_prompt_box",
              "visibleWorking": true,
              "lineRegex": [
                "(?i)^\\s*[·✢✳✶✻✽]\\s+waiting for \\d"
              ]
            },
            {
              "id": "spinner_tokens_working_local",
              "state": "working",
              "priority": 960,
              "region": "bottom_non_empty_lines_above_prompt_box(10)",
              "visibleWorking": true,
              "lineRegex": [
                "\\((?:\\d+h )?(?:\\d+m )?\\d+s ·[^)]*tokens"
              ]
            },
            {
              "id": "spinner_footer_working_local",
              "state": "working",
              "priority": 955,
              "region": "bottom_non_empty_lines_above_prompt_box(10)",
              "visibleWorking": true,
              "contains": [
                "esc to interrupt"
              ]
            },
            {
              "id": "spinner_glyph_working_local",
              "state": "working",
              "priority": 958,
              "region": "bottom_non_empty_lines_above_prompt_box(10)",
              "visibleWorking": true,
              "any": [
                {
                  "lineRegex": [
                    "^\\s*[·✢✳✶✻✽]\\s+\\S.*\\((?:\\d+h )?(?:\\d+m )?\\d+s"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*[·✢✳✶✻✽]\\s+\\S.*…"
                  ]
                }
              ]
            },
            {
              "id": "input_box_idle_local",
              "state": "idle",
              "priority": 951,
              "region": "bottom_non_empty_lines(14)",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*[│┃]\\s*>(\\s|$)"
              ],
              "not": [
                {
                  "contains": [
                    "enter to select"
                  ]
                },
                {
                  "contains": [
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "tab/arrow keys"
                  ]
                },
                {
                  "contains": [
                    "arrow keys to navigate"
                  ]
                },
                {
                  "contains": [
                    "↑/↓ to navigate"
                  ]
                }
              ]
            }
          ]
        },
        {
          "id": "codex",
          "displayName": "Codex",
          "identity": {
            "screenSignatures": [
              {
                "contains": [
                  "openai codex"
                ],
                "altScreenOnly": true
              },
              {
                "lineRegex": [
                  "^\\s*[•◦]\\s+.*\\((?:\\d+h )?(?:\\d+m )?\\d+s • esc to interrupt\\)"
                ]
              },
              {
                "lineRegex": [
                  "(?i)^\\s*gpt-\\S+(?: [a-z][a-z-]*)+ ·"
                ]
              },
              {
                "lineRegex": [
                  "^\\s*›(?: |$)",
                  "(?i)^\\s*\\S+(?: [a-z][a-z-]*)+ · .*\\bcontext\\s+\\d+%\\s+used\\b"
                ],
                "region": "bottom_non_empty_lines(6)"
              },
              {
                "any": [
                  {
                    "regex": [
                      "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\s+or\\s+esc\\s+to\\s+cancel\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\benter\\s+to\\s+submit\\s+(?:answer|all)\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\benter\\s+to\\s+submit(?:\\s+(?:answer|all))?\\b.*\\besc\\s+to\\s+cancel\\b"
                    ]
                  }
                ],
                "region": "after_last_prompt_marker"
              },
              {
                "regex": [
                  "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\b"
                ],
                "any": [
                  {
                    "regex": [
                      "(?is)\\bwould\\s+you\\s+like\\s+to\\s+run\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\bwould\\s+you\\s+like\\s+to\\s+make\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\bwould\\s+you\\s+like\\s+to\\s+grant\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\bdo\\s+you\\s+want\\s+to\\s+approve\\b"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\bneeds\\s+your\\b"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "regex": [
                  "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\b"
                ],
                "any": [
                  {
                    "regex": [
                      "(?is)\\bimplement\\s+this\\s+plan\\?"
                    ]
                  },
                  {
                    "regex": [
                      "(?is)\\bsubmit\\s+with\\s+unanswered\\s+questions\\?"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "regex": [
                  "(?is)\\bapproval\\s+needed\\s+in\\b",
                  "(?is)/agent\\s+to\\b"
                ],
                "region": "bottom_non_empty_lines(12)"
              }
            ],
            "commands": [
              "codex"
            ]
          },
          "rules": [
            {
              "id": "osc_title_blocked",
              "state": "blocked",
              "priority": 1100,
              "region": "osc_title",
              "visibleBlocker": true,
              "contains": [
                "Action Required"
              ]
            },
            {
              "id": "osc_title_working",
              "state": "working",
              "priority": 1050,
              "region": "osc_title",
              "visibleWorking": true,
              "regex": [
                "(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"
              ]
            },
            {
              "id": "transcript_viewer",
              "state": "unknown",
              "priority": 1000,
              "region": "after_last_prompt_marker",
              "skipStateUpdate": true,
              "contains": [
                "↑/↓ to scroll",
                "pgup/pgdn to",
                "home/end to jump",
                "q to quit"
              ],
              "any": [
                {
                  "contains": [
                    "esc to edit prev"
                  ]
                },
                {
                  "contains": [
                    "esc/← to edit prev"
                  ]
                }
              ]
            },
            {
              "id": "live_strong_blocker",
              "state": "blocked",
              "priority": 900,
              "region": "after_last_prompt_marker",
              "visibleBlocker": true,
              "any": [
                {
                  "contains": [
                    "press enter to confirm or esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "enter to submit answer"
                  ]
                },
                {
                  "contains": [
                    "enter to submit all"
                  ]
                },
                {
                  "contains": [
                    "allow command?"
                  ]
                }
              ]
            },
            {
              "id": "weak_blocker",
              "state": "blocked",
              "priority": 600,
              "region": "bottom_non_empty_lines(8)",
              "any": [
                {
                  "contains": [
                    "[y/n]"
                  ]
                },
                {
                  "contains": [
                    "yes (y)"
                  ]
                },
                {
                  "contains": [
                    "do you want to"
                  ],
                  "any": [
                    {
                      "contains": [
                        "yes"
                      ]
                    },
                    {
                      "contains": [
                        "❯"
                      ]
                    }
                  ]
                },
                {
                  "contains": [
                    "would you like to"
                  ],
                  "any": [
                    {
                      "contains": [
                        "yes"
                      ]
                    },
                    {
                      "contains": [
                        "❯"
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "id": "screen_working_fallback",
              "state": "working",
              "priority": 500,
              "region": "bottom_non_empty_lines(3)",
              "visibleWorking": true,
              "lineRegex": [
                "^\\s*[•◦]\\s+.*\\((?:\\d+h )?(?:\\d+m )?\\d+s • esc to interrupt\\)(?: · .*)?$"
              ],
              "not": [
                {
                  "contains": [
                    "■ Conversation interrupted"
                  ]
                }
              ]
            },
            {
              "id": "osc_title_idle",
              "state": "idle",
              "priority": 100,
              "region": "osc_title",
              "visibleIdle": true,
              "regex": [
                "\\S"
              ],
              "not": [
                {
                  "regex": [
                    "(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"
                  ]
                },
                {
                  "contains": [
                    "Action Required"
                  ]
                }
              ]
            },
            {
              "id": "screen_working_local",
              "state": "working",
              "priority": 660,
              "region": "bottom_non_empty_lines(6)",
              "visibleWorking": true,
              "lineRegex": [
                "^\\s*[•◦]\\s+.*\\((?:\\d+h )?(?:\\d+m )?\\d+s • esc to interrupt\\)"
              ]
            },
            {
              "id": "live_composer_idle_local",
              "state": "idle",
              "priority": 650,
              "region": "bottom_non_empty_lines(6)",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*›(?: |$)"
              ],
              "any": [
                {
                  "lineRegex": [
                    "(?i)^\\s*gpt-\\S+ (minimal|low|medium|high|xhigh|default) ·"
                  ]
                },
                {
                  "lineRegex": [
                    "(?i)^\\s*\\S+ [a-z][a-z-]* · .*\\bcontext\\s+\\d+%\\s+used\\b"
                  ]
                }
              ],
              "not": [
                {
                  "contains": [
                    "[y/n]"
                  ]
                },
                {
                  "contains": [
                    "yes (y)"
                  ]
                }
              ]
            },
            {
              "id": "live_interactive_blocker_local",
              "state": "blocked",
              "priority": 1200,
              "region": "after_last_prompt_marker",
              "visibleBlocker": true,
              "any": [
                {
                  "regex": [
                    "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\s+or\\s+esc\\s+to\\s+cancel\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\benter\\s+to\\s+submit\\s+(?:answer|all)\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\benter\\s+to\\s+submit(?:\\s+(?:answer|all))?\\b.*\\besc\\s+to\\s+cancel\\b"
                  ]
                }
              ]
            },
            {
              "id": "clipped_approval_blocker_local",
              "state": "blocked",
              "priority": 1200,
              "region": "bottom_non_empty_lines(20)",
              "visibleBlocker": true,
              "regex": [
                "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\b"
              ],
              "any": [
                {
                  "regex": [
                    "(?is)\\bwould\\s+you\\s+like\\s+to\\s+run\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\bwould\\s+you\\s+like\\s+to\\s+make\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\bwould\\s+you\\s+like\\s+to\\s+grant\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\bdo\\s+you\\s+want\\s+to\\s+approve\\b"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\bneeds\\s+your\\b"
                  ]
                }
              ]
            },
            {
              "id": "confirmation_blocker_local",
              "state": "blocked",
              "priority": 1200,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "regex": [
                "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\b"
              ],
              "any": [
                {
                  "regex": [
                    "(?is)\\bimplement\\s+this\\s+plan\\?"
                  ]
                },
                {
                  "regex": [
                    "(?is)\\bsubmit\\s+with\\s+unanswered\\s+questions\\?"
                  ]
                }
              ]
            },
            {
              "id": "selection_menu_open_local",
              "state": "unknown",
              "priority": 1190,
              "region": "after_last_prompt_marker",
              "skipStateUpdate": true,
              "regex": [
                "(?is)\\bpress\\s+enter\\s+to\\s+confirm\\b"
              ]
            },
            {
              "id": "pending_thread_approval_local",
              "state": "blocked",
              "priority": 1200,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "regex": [
                "(?is)\\bapproval\\s+needed\\s+in\\b",
                "(?is)/agent\\s+to\\b"
              ]
            }
          ]
        },
        {
          "id": "copilot",
          "displayName": "GitHub Copilot",
          "identity": {
            "screenSignatures": [
              {
                "contains": [
                  "github copilot"
                ],
                "altScreenRequired": true
              },
              {
                "contains": [
                  "type @ to mention files"
                ]
              },
              {
                "contains": [
                  "shift+tab switch mode"
                ]
              },
              {
                "contains": [
                  "copilot uses ai"
                ]
              },
              {
                "contains": [
                  "copilot may read files in this folder"
                ]
              },
              {
                "contains": [
                  "run /init to generate",
                  "copilot-instructions.md"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "contains": [
                  "the ai model to use for copilot"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "regex": [
                  "(?i)\\bsession:\\s*\\S+\\s*aic\\s+used\\b"
                ],
                "region": "bottom_non_empty_lines(10)"
              },
              {
                "contains": [
                  "? help",
                  "tab next tab"
                ],
                "region": "bottom_non_empty_lines(4)"
              }
            ],
            "commands": [
              "copilot",
              "github-copilot",
              "ghcs"
            ]
          },
          "rules": [
            {
              "id": "session_status_idle",
              "state": "idle",
              "priority": 90,
              "region": "bottom_non_empty_lines(10)",
              "visibleIdle": true,
              "regex": [
                "(?i)\\bsession:\\s*\\S+\\s*aic\\s+used\\b"
              ],
              "not": [
                {
                  "contains": [
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "esc again to cancel"
                  ]
                },
                {
                  "contains": [
                    "esc interrupt"
                  ]
                },
                {
                  "contains": [
                    "esc to interrupt"
                  ]
                }
              ]
            },
            {
              "id": "selection_blocker",
              "state": "blocked",
              "priority": 300,
              "region": "bottom_non_empty_lines(8)",
              "visibleBlocker": true,
              "all": [
                {
                  "any": [
                    {
                      "contains": [
                        "esc to cancel"
                      ]
                    },
                    {
                      "contains": [
                        "esc cancel"
                      ]
                    }
                  ]
                },
                {
                  "any": [
                    {
                      "contains": [
                        "enter to select"
                      ]
                    },
                    {
                      "contains": [
                        "enter to confirm"
                      ]
                    },
                    {
                      "contains": [
                        "enter to submit"
                      ]
                    },
                    {
                      "contains": [
                        "enter accept"
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "id": "working_cancel_hint",
              "state": "working",
              "priority": 100,
              "region": "bottom_non_empty_lines(10)",
              "visibleWorking": true,
              "any": [
                {
                  "contains": [
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "esc again to cancel"
                  ]
                },
                {
                  "contains": [
                    "esc interrupt"
                  ]
                }
              ]
            },
            {
              "id": "dialog_blocked_local",
              "state": "blocked",
              "priority": 320,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "regex": [
                "(?im)^[\\s│┃]*❯\\s*\\d+\\.\\s"
              ],
              "any": [
                {
                  "contains": [
                    "esc to cancel"
                  ]
                },
                {
                  "contains": [
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "to navigate"
                  ]
                },
                {
                  "contains": [
                    "confirm with number keys"
                  ]
                }
              ]
            },
            {
              "id": "number_picker_blocked_local",
              "state": "blocked",
              "priority": 310,
              "region": "bottom_non_empty_lines(8)",
              "visibleBlocker": true,
              "contains": [
                "confirm with number keys"
              ]
            },
            {
              "id": "composer_idle_local",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(8)",
              "visibleIdle": true,
              "contains": [
                "shift+tab switch mode"
              ],
              "lineRegex": [
                "^\\s*❯(\\s|$)"
              ]
            }
          ]
        },
        {
          "id": "cursor",
          "displayName": "Cursor Agent",
          "identity": {
            "screenSignatures": [
              {
                "contains": [
                  "cursor agent"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "lineRegex": [
                  "^\\s*[⬡⬢]\\s+\\p{Alphabetic}+\\w*ing\\b"
                ]
              },
              {
                "contains": [
                  "plan, search, build anything"
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "lineRegex": [
                  "^\\s*→\\s",
                  "^\\s*[~/]\\S*\\s+·\\s+\\S+\\s*$"
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "contains": [
                  "space select",
                  "enter next/submit"
                ],
                "region": "bottom_non_empty_lines(8)"
              }
            ],
            "commands": [
              "cursor-agent",
              "cursor"
            ]
          },
          "rules": [
            {
              "id": "write_file_approval",
              "state": "blocked",
              "priority": 320,
              "region": "bottom_non_empty_lines(8)",
              "visibleBlocker": true,
              "contains": [
                "write to this file?",
                "proceed (y)"
              ],
              "any": [
                {
                  "contains": [
                    "reject & propose changes"
                  ]
                },
                {
                  "contains": [
                    "esc or n or p"
                  ]
                },
                {
                  "contains": [
                    "add write("
                  ]
                }
              ]
            },
            {
              "id": "approval_prompt",
              "state": "blocked",
              "priority": 300,
              "region": "whole_recent",
              "visibleBlocker": true,
              "any": [
                {
                  "contains": [
                    "waiting for approval",
                    "run this command?"
                  ],
                  "any": [
                    {
                      "contains": [
                        "run (once) (y)"
                      ]
                    },
                    {
                      "contains": [
                        "skip (esc or n)"
                      ]
                    }
                  ]
                },
                {
                  "contains": [
                    "(y) (enter)"
                  ]
                },
                {
                  "lineRegex": [
                    "(?i)^\\s*allow .*\\(y\\)"
                  ]
                },
                {
                  "contains": [
                    "keep (n)"
                  ]
                },
                {
                  "contains": [
                    "skip (esc or n)"
                  ]
                },
                {
                  "lineRegex": [
                    "(?i)^\\s*(run |.*\\(y\\).*(allow|run \\(once\\)|→ run))"
                  ]
                }
              ]
            },
            {
              "id": "stop_hint_working",
              "state": "working",
              "priority": 100,
              "region": "bottom_non_empty_lines(6)",
              "visibleWorking": true,
              "contains": [
                "ctrl+c to stop"
              ]
            },
            {
              "id": "background_task_status_working",
              "state": "working",
              "priority": 95,
              "region": "bottom_non_empty_lines(5)",
              "visibleWorking": true,
              "lineRegex": [
                "(?i)\\b[1-9][0-9]*\\s+background\\s+tasks?\\b"
              ]
            },
            {
              "id": "spinner_working",
              "state": "working",
              "priority": 90,
              "region": "bottom_non_empty_lines(8)",
              "visibleWorking": true,
              "lineRegex": [
                "^\\s*(⬡|⬢|[\\u{2800}-\\u{28FF}]+)\\s+\\p{Alphabetic}+\\w*ing\\b"
              ]
            },
            {
              "id": "question_dialog_blocked_local",
              "state": "blocked",
              "priority": 310,
              "region": "bottom_non_empty_lines(8)",
              "visibleBlocker": true,
              "contains": [
                "space select",
                "enter next/submit"
              ]
            },
            {
              "id": "composer_idle_local",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(8)",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*→\\s",
                "^\\s*[~/]\\S*\\s+·\\s+\\S+\\s*$"
              ]
            }
          ]
        },
        {
          "id": "helix",
          "displayName": "Helix"
        },
        {
          "id": "omp",
          "displayName": "oh-my-pi",
          "identity": {
            "titlePatterns": [
              "^π\\s*[>!:\\u{2800}-\\u{28FF}]"
            ],
            "screenSignatures": [
              {
                "lineRegex": [
                  "^\\s*[╭┌+][─\\-]{2,}.*?(?:\\d+(?:\\.\\d+)?%/\\d+(?:\\.\\d+)?\\s*[kmbKMB]?|\\d+(?:\\.\\d+)?\\s*[kmbKMB]?/\\?)"
                ],
                "not": [
                  {
                    "contains": [
                      "resume this session with omp"
                    ]
                  },
                  {
                    "contains": [
                      "closing session"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "any": [
                  {
                    "lineRegex": [
                      "^\\s*╰─\\s.{2,}─╯\\s*$"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*\\+-\\s.{2,}-\\+\\s*$"
                    ]
                  }
                ],
                "not": [
                  {
                    "contains": [
                      "resume this session with omp"
                    ]
                  },
                  {
                    "contains": [
                      "closing session"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "any": [
                  {
                    "lineRegex": [
                      "^\\s*[\\u{2800}-\\u{28FF}]\\s+\\S.*(?:⟦esc⟧|⟨esc⟩|\\[esc\\])\\s*$"
                    ]
                  },
                  {
                    "lineRegex": [
                      "^\\s*[|/\\\\-]\\s+\\S.*(?:⟦esc⟧|⟨esc⟩|\\[esc\\])\\s*$"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(8)"
              },
              {
                "contains": [
                  "plan mode - next step",
                  "approve and execute"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "allow tool:"
                ],
                "any": [
                  {
                    "regex": [
                      "(?im)^\\s*(?:[│┃|]\\s*)?❯\\s*approve\\b"
                    ]
                  },
                  {
                    "contains": [
                      "approve",
                      "deny"
                    ]
                  }
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "enter confirm",
                  "esc skip"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "enter assign roles",
                  "esc close"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "press enter to skip"
                ],
                "lineRegex": [
                  "^[\\s\\u{2580}-\\u{259F}]*[\\u{2580}-\\u{259F}][\\s\\u{2580}-\\u{259F}]*$"
                ],
                "altScreenRequired": true
              },
              {
                "contains": [
                  "handing off to the normal cli"
                ],
                "lineRegex": [
                  "^[\\s\\u{2580}-\\u{259F}]*[\\u{2580}-\\u{259F}][\\s\\u{2580}-\\u{259F}]*$"
                ],
                "altScreenRequired": true
              },
              {
                "contains": [
                  "smol",
                  "fallbacks:"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "contains": [
                  "⦸ off",
                  "⟳ auto"
                ],
                "region": "bottom_non_empty_lines(12)"
              },
              {
                "lineRegex": [
                  "^\\s*[╭┌+][─\\-]{2,}.*\\somp\\sv\\d"
                ],
                "region": "bottom_non_empty_lines(20)"
              }
            ],
            "commands": [
              "omp",
              "oh-my-pi"
            ]
          },
          "rules": [
            {
              "id": "osc_title_blocked",
              "state": "blocked",
              "priority": 1100,
              "region": "osc_title",
              "visibleBlocker": true,
              "regex": [
                "^\\s*\\u{03C0}\\s*!"
              ]
            },
            {
              "id": "osc_title_working",
              "state": "working",
              "priority": 1050,
              "region": "osc_title",
              "visibleWorking": true,
              "regex": [
                "^\\s*\\u{03C0}\\s*[\\u{2800}-\\u{28FF}]"
              ]
            },
            {
              "id": "tool_approval_blocked",
              "state": "blocked",
              "priority": 500,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "contains": [
                "allow tool:"
              ],
              "any": [
                {
                  "regex": [
                    "(?im)^\\s*(?:[│┃|]\\s*)?❯\\s*approve\\b"
                  ]
                },
                {
                  "contains": [
                    "approve",
                    "deny"
                  ]
                }
              ]
            },
            {
              "id": "plan_review_blocked",
              "state": "blocked",
              "priority": 500,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "contains": [
                "plan mode - next step",
                "approve and execute"
              ]
            },
            {
              "id": "selection_blocker",
              "state": "blocked",
              "priority": 300,
              "region": "bottom_non_empty_lines(12)",
              "visibleBlocker": true,
              "any": [
                {
                  "contains": [
                    "enter select",
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "enter toggle",
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "⏎ confirm",
                    "esc cancel"
                  ]
                },
                {
                  "contains": [
                    "enter confirm",
                    "esc skip"
                  ]
                },
                {
                  "contains": [
                    "enter assign roles",
                    "esc close"
                  ]
                },
                {
                  "contains": [
                    "smol",
                    "fallbacks:"
                  ]
                },
                {
                  "contains": [
                    "⦸ off",
                    "⟳ auto"
                  ]
                }
              ]
            },
            {
              "id": "spinner_working",
              "state": "working",
              "priority": 100,
              "region": "bottom_non_empty_lines(8)",
              "visibleWorking": true,
              "any": [
                {
                  "lineRegex": [
                    "^\\s*[\\u{2800}-\\u{28FF}]\\s+\\S.*(?:⟦esc⟧|⟨esc⟩|\\[esc\\])\\s*$"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*[|/\\\\-]\\s+\\S.*(?:⟦esc⟧|⟨esc⟩|\\[esc\\])\\s*$"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*[\\u{2800}-\\u{28FF}|/\\\\-]\\s+\\S.*\\(esc to cancel\\)\\s*$"
                  ]
                }
              ]
            },
            {
              "id": "status_bar_idle",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(12)",
              "visibleIdle": true,
              "any": [
                {
                  "lineRegex": [
                    "^\\s*[╭┌+][\\u{2500}\\-]{2,}.*?(?:\\d+(?:\\.\\d+)?%/\\d+(?:\\.\\d+)?\\s*[kmbKMB]?|\\d+(?:\\.\\d+)?\\s*[kmbKMB]?/\\?)"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*\\u{2570}\\u{2500}\\s.{2,}\\u{2500}\\u{256F}\\s*$"
                  ]
                },
                {
                  "lineRegex": [
                    "^\\s*\\+-\\s.{2,}-\\+\\s*$"
                  ]
                }
              ],
              "not": [
                {
                  "contains": [
                    "⟦esc⟧"
                  ]
                },
                {
                  "contains": [
                    "⟨esc⟩"
                  ]
                },
                {
                  "contains": [
                    "[esc]"
                  ]
                },
                {
                  "contains": [
                    "(esc to cancel)"
                  ]
                },
                {
                  "contains": [
                    "resume this session with omp"
                  ]
                },
                {
                  "contains": [
                    "closing session"
                  ]
                }
              ]
            },
            {
              "id": "osc_title_idle",
              "state": "idle",
              "priority": 70,
              "region": "osc_title",
              "visibleIdle": true,
              "regex": [
                "^\\s*\\u{03C0}\\s*[>:]"
              ]
            }
          ]
        },
        {
          "id": "opencode",
          "displayName": "OpenCode",
          "identity": {
            "screenSignatures": [
              {
                "contains": [
                  "opencode"
                ],
                "altScreenRequired": true
              },
              {
                "contains": [
                  "tab agents",
                  "ctrl+p commands"
                ]
              },
              {
                "lineRegex": [
                  "(?i)^\\s*continue\\s+opencode\\s+-s\\s+\\S"
                ],
                "region": "bottom_non_empty_lines(12)"
              }
            ],
            "commands": [
              "opencode",
              "open-code"
            ]
          },
          "rules": [
            {
              "id": "permission_required",
              "state": "blocked",
              "priority": 300,
              "region": "whole_recent",
              "visibleBlocker": true,
              "any": [
                {
                  "contains": [
                    "△ Permission required"
                  ]
                },
                {
                  "contains": [
                    "esc dismiss"
                  ],
                  "all": [
                    {
                      "any": [
                        {
                          "contains": [
                            "↑↓ select"
                          ]
                        },
                        {
                          "contains": [
                            "⇆ tab"
                          ]
                        }
                      ]
                    }
                  ],
                  "any": [
                    {
                      "contains": [
                        "enter confirm"
                      ]
                    },
                    {
                      "contains": [
                        "enter submit"
                      ]
                    },
                    {
                      "contains": [
                        "enter toggle"
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "id": "interrupt_hint_working",
              "state": "working",
              "priority": 110,
              "region": "whole_recent",
              "visibleWorking": true,
              "any": [
                {
                  "contains": [
                    "esc to interrupt"
                  ]
                },
                {
                  "contains": [
                    "ctrl+c to interrupt"
                  ]
                },
                {
                  "contains": [
                    "press esc to interrupt"
                  ]
                },
                {
                  "lineRegex": [
                    "(?i).*opencode.*esc (again to )?interrupt"
                  ]
                }
              ]
            },
            {
              "id": "progress_bar_working",
              "state": "working",
              "priority": 100,
              "region": "whole_recent",
              "visibleWorking": true,
              "regex": [
                "(■|⬝){4,}"
              ]
            },
            {
              "id": "composer_idle_local",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(8)",
              "visibleIdle": true,
              "lineRegex": [
                "^\\s*╹▀{8,}"
              ]
            }
          ]
        },
        {
          "id": "pi",
          "displayName": "Pi",
          "identity": {
            "screenSignatures": [
              {
                "contains": [
                  "ctrl+c/ctrl+d clear/exit"
                ],
                "region": "bottom_non_empty_lines(20)"
              },
              {
                "lineRegex": [
                  "\\d+(?:\\.\\d+)?%/\\d+[kmb]?\\s+\\(\\w+\\)"
                ],
                "region": "bottom_non_empty_lines(6)"
              }
            ],
            "commands": [
              "pi"
            ]
          },
          "rules": [
            {
              "id": "working_literal",
              "state": "working",
              "priority": 100,
              "region": "whole_recent",
              "visibleWorking": true,
              "contains": [
                "Working..."
              ]
            },
            {
              "id": "status_bar_idle_local",
              "state": "idle",
              "priority": 80,
              "region": "bottom_non_empty_lines(6)",
              "visibleIdle": true,
              "lineRegex": [
                "\\d+(?:\\.\\d+)?%/\\d+[kmb]?\\s+\\(\\w+\\)"
              ]
            }
          ]
        },
        {
          "id": "vim",
          "displayName": "Vim"
        }
      ]
    }
    """#
}
