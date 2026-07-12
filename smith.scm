(require "helix/static.scm")
(require (prefix-in helix.misc. "helix/misc.scm"))
(require (prefix-in keymaps. "helix/keymaps.scm"))
(require "steel/result")
(require-builtin steel/filesystem)
(require-builtin steel/process)

(provide smith-root
         smith-registry-path
         smith-registry
         smith-lock-path
         smith-lock
         smith-restore
         smith-init
         smith-self-update
         smith-ensure
         smith-plugin
         smith-configure!
         smith-prune
         smith-list
         smith-install
         smith-update
         smith-remove
         smith-enable
         smith-disable
         smith-load
         smith-load-all)

(define (smith-path-join . parts)
  (cond
    [(null? parts) ""]
    [(null? (cdr parts)) (car parts)]
    [else
     (let ([left (trim-end-matches (car parts) "/")]
           [right (trim-start-matches (apply smith-path-join (cdr parts)) "/")])
       (string-append left "/" right))]))

(define (smith-config-root)
  (parent-name (get-init-scm-path)))

;;@doc
;; Directory where this manager keeps its registry and command logs.
(define (smith-root)
  (smith-path-join (smith-config-root) "steel" "plugins"))

;;@doc
;; File where the plugin manager stores installed plugin metadata.
(define (smith-registry-path)
  (smith-path-join (smith-root) "registry.scm"))

(define (smith-lock-path)
  (smith-path-join (smith-root) "smith-lock.scm"))

;; Forge installs packages below Steel's cogs directory.
(define (smith-forge-root)
  (smith-path-join (steel-home-location) "cogs"))

(define *smith-source*
  "https://github.com/kn66/smith.hx.git")

(define (smith-ensure-root!)
  (unless (path-exists? (smith-root))
    (create-directory! (smith-root))))

(define (smith-file->string path)
  (let ([port (open-input-file path)])
    (let ([contents (read-port-to-string port)])
      (close-port port)
      contents)))

(define (smith-make-plugin name source entry branch enabled?)
  (list name source entry branch enabled?))

(define (smith-plugin-name plugin) (list-ref plugin 0))
(define (smith-plugin-source plugin) (list-ref plugin 1))
(define (smith-plugin-entry plugin) (list-ref plugin 2))
(define (smith-plugin-branch plugin) (list-ref plugin 3))
(define (smith-plugin-enabled? plugin) (list-ref plugin 4))

(define (smith-plugin-path name)
  (smith-path-join (smith-forge-root) name))

;; Names declared by smith-ensure during the current init.scm evaluation.
;; The registry remains the durable record of packages managed by this module.
(define *smith-declared-plugin-names* '())

(define (smith-declare-plugin! name)
  (unless (member name *smith-declared-plugin-names*)
    (set! *smith-declared-plugin-names* (cons name *smith-declared-plugin-names*))))

;;@doc
;; Return the raw plugin registry as a list.
(define (smith-registry)
  (let ([registry (smith-registry-path)])
    (if (path-exists? registry)
        (let ([port (open-input-file registry)])
          (let ([plugins (read port)])
            (close-port port)
            plugins))
        '())))

(define (smith-save-registry! plugins)
  (smith-ensure-root!)
  (let ([port (open-output-file (smith-registry-path) #:exists 'truncate)])
    (write plugins port)
    (display "\n" port)
    (close-port port)))

(define (smith-remove-spec name plugins)
  (cond
    [(null? plugins) '()]
    [(equal? name (smith-plugin-name (car plugins))) (smith-remove-spec name (cdr plugins))]
    [else (cons (car plugins) (smith-remove-spec name (cdr plugins)))]))

(define (smith-upsert-spec plugin plugins)
  (cons plugin (smith-remove-spec (smith-plugin-name plugin) plugins)))

(define (smith-find-spec name plugins)
  (cond
    [(null? plugins) #false]
    [(equal? name (smith-plugin-name (car plugins))) (car plugins)]
    [else (smith-find-spec name (cdr plugins))]))

(define (smith-find-spec-by-source source plugins)
  (cond
    [(null? plugins) #false]
    [(equal? source (smith-plugin-source (car plugins))) (car plugins)]
    [else (smith-find-spec-by-source source (cdr plugins))]))

(define (smith-replace-spec plugin plugins)
  (smith-upsert-spec plugin plugins))

(define (smith-valid-name? name)
  (and (not (equal? name ""))
       (not (string-contains? name "/"))
       (not (string-contains? name "\\"))
       (not (string-contains? name ":"))
       (not (string-contains? name ".."))))

(define (smith-assert-valid-name! name)
  (unless (smith-valid-name? name)
    (error (string-append "invalid plugin name: " name))))

(define (smith-last-item items)
  (if (null? (cdr items))
      (car items)
      (smith-last-item (cdr items))))

(define (smith-strip-url-suffixes source)
  (let* ([no-query (car (split-many source "?"))]
         [no-fragment (car (split-many no-query "#"))])
    (trim-end-matches no-fragment "/")))

(define (smith-derive-name source)
  (let* ([cleaned (smith-strip-url-suffixes source)]
         [last-path-part (smith-last-item (split-many cleaned "/"))]
         [last-scp-part (smith-last-item (split-many last-path-part ":"))]
         [name (trim-end-matches last-scp-part ".git")])
    (smith-assert-valid-name! name)
    name))

(define (smith-github-shorthand? source)
  (and (not (string-contains? source "://"))
       (not (starts-with? source "git@"))
       (= (length (split-many source "/")) 2)))

(define (smith-normalize-source source)
  (if (smith-github-shorthand? source)
      (string-append "https://github.com/" source ".git")
      source))

(define (smith-quote-string value)
  (string-append "\""
                 (string-replace
                   (string-replace value "\\" "\\\\")
                   "\""
                   "\\\"")
                 "\""))

(define (smith-run-command program args cwd)
  (smith-ensure-root!)
  (let* ([stdout-path (smith-path-join (smith-root) ".last-command.stdout")]
         [stderr-path (smith-path-join (smith-root) ".last-command.stderr")]
         [builder (command program args)])
    (when cwd (with-current-dir builder cwd))
    (with-stdout builder (open-output-file stdout-path #:exists 'truncate))
    (with-stderr builder (open-output-file stderr-path #:exists 'truncate))
    (let* ([child (unwrap-ok (spawn-process builder))]
           [status (unwrap-ok (wait child))]
           [stdout (smith-file->string stdout-path)]
           [stderr (smith-file->string stderr-path)])
      (if (equal? status 0)
          stdout
          (error
            (string-append program
                           " failed with status "
                           (to-string status)
                           "\n"
                           stdout
                           stderr))))))

(define (smith-run-forge args)
  (smith-run-command "forge" args #false))

(define (smith-installed-path output)
  (let ([matches
         (filter (lambda (line) (string-contains? line "Installed package to:"))
                 (split-many output "\n"))])
    (if (null? matches)
        #false
        (trim (smith-last-item
                (split-many (smith-last-item matches) "Installed package to:"))))))

(define (smith-forge-install-source! source branch force?)
  (let* ([args (append (list "pkg" "install" "--git" source)
                       (if branch (list "--rev" branch) '())
                       (if force? (list "--force") '()))]
         [output (smith-run-forge args)]
         [installed-path (smith-installed-path output)])
    (unless installed-path
      (error "Forge did not report the installed package path"))
    installed-path))

(define (smith-forge-install! plugin force?)
  (let ([installed-path
         (smith-forge-install-source! (smith-plugin-source plugin)
                                      (smith-plugin-branch plugin)
                                      force?)])
    (unless (path-exists? (smith-plugin-directory plugin))
      (error
        (string-append
          "Forge installed package name does not match expected name: "
          (smith-plugin-name plugin)
          ". Installed to "
          installed-path
          "; check package-name in cog.scm.")))))

(define (smith-plugin-directory plugin)
  (smith-plugin-path (smith-plugin-name plugin)))

(define (smith-candidate-entries name)
  (list "helix.scm" "init.scm" "plugin.scm" (string-append name ".scm") "cog.scm"))

(define (smith-first-existing-entry smith-plugin-directory entries)
  (cond
    [(null? entries) #false]
    [(path-exists? (smith-path-join smith-plugin-directory (car entries))) (car entries)]
    [else (smith-first-existing-entry smith-plugin-directory (cdr entries))]))

(define (smith-resolve-entry smith-plugin-directory requested-entry name)
  (cond
    [requested-entry
     (if (path-exists? (smith-path-join smith-plugin-directory requested-entry))
         requested-entry
         (error (string-append "plugin entry not found: " requested-entry)))]
    [else
     (let ([entry (smith-first-existing-entry smith-plugin-directory (smith-candidate-entries name))])
       (if entry
           entry
           (error
             (string-append
               "plugin entry not found. Expected helix.scm, init.scm, plugin.scm, "
               name
               ".scm, or cog.scm"))))]))

(define (smith-resolve-existing-entry smith-plugin-directory plugin requested-entry)
  (cond
    [requested-entry
     (smith-resolve-entry smith-plugin-directory requested-entry (smith-plugin-name plugin))]
    [(path-exists? (smith-path-join smith-plugin-directory (smith-plugin-entry plugin)))
     (smith-plugin-entry plugin)]
    [else
     (smith-resolve-entry smith-plugin-directory #false (smith-plugin-name plugin))]))

(define (smith-load-spec plugin)
  (let* ([entry-path (smith-path-join (smith-plugin-path (smith-plugin-name plugin)) (smith-plugin-entry plugin))]
         [require-expression (string-append "(require " (smith-quote-string entry-path) ")")])
    (unless (path-exists? entry-path)
      (error (string-append "plugin entry not found: " entry-path)))
    (eval-string require-expression)
    (string-append "loaded " (smith-plugin-name plugin))))

(define (smith-install-existing plugin target entry branch)
  (let ([resolved-entry (smith-resolve-existing-entry target plugin entry)])
    (when (and branch (not (equal? branch (smith-plugin-branch plugin))))
      (error
        (string-append
          "plugin already installed with a different branch: "
          (smith-plugin-name plugin))))
    (let ([updated (smith-make-plugin (smith-plugin-name plugin)
                                (smith-plugin-source plugin)
                                resolved-entry
                                (smith-plugin-branch plugin)
                                #true)])
      (smith-save-registry! (smith-replace-spec updated (smith-registry)))
      (smith-load-spec updated)
      (string-append "already installed " (smith-plugin-name plugin)))))

;;@doc
;; Install a plugin through Forge and load its entry file.
;;
;; `source` can be a full git URL or a GitHub shorthand such as "owner/repo".
;; `name`, `entry`, and revision are optional. The entry defaults to the first
;; existing file from helix.scm, init.scm, plugin.scm, cog.scm, or <name>.scm.
(define (smith-install source [name #false] [entry #false] [branch #false])
  (let* ([url (smith-normalize-source source)]
         [plugins (smith-registry)]
         [existing (if name
                       (smith-find-spec name plugins)
                       (smith-find-spec-by-source url plugins))])
    (smith-ensure-root!)
    (cond
      [existing
       (unless (equal? url (smith-plugin-source existing))
         (error
           (string-append
             "plugin already installed with a different source: "
             (smith-plugin-name existing))))
       (let ([target (smith-plugin-directory existing)])
       (if (path-exists? target)
           (smith-install-existing existing target entry branch)
           (begin
             (smith-forge-install! existing #false)
             (smith-install-existing existing target entry branch))))]
      [(and name (path-exists? (smith-plugin-path name)))
       (smith-assert-valid-name! name)
       (let ([target (smith-plugin-path name)])
       (let* ([resolved-entry (smith-resolve-entry target entry name)]
              [plugin (smith-make-plugin name url resolved-entry branch #true)])
         (smith-save-registry! (smith-upsert-spec plugin plugins))
         (smith-load-spec plugin)
           (string-append "registered existing " name)))]
      [else
       ;; Force the first unmanaged install so Forge always reports the root
       ;; package path, even when it was installed independently beforehand.
       (let* ([target (smith-forge-install-source! url branch (not name))]
              [smith-plugin-name (or name (file-name target))]
              [expected-target (smith-plugin-path smith-plugin-name)])
         (smith-assert-valid-name! smith-plugin-name)
         (unless (equal? target expected-target)
           (error (string-append "Forge package name does not match explicit name: "
                                 smith-plugin-name
                                 "; installed to "
                                 target)))
         (let* ([resolved-entry (smith-resolve-entry target entry smith-plugin-name)]
                [plugin (smith-make-plugin smith-plugin-name url resolved-entry branch #true)])
         (smith-save-registry! (smith-upsert-spec plugin (smith-registry)))
         (smith-load-spec plugin)
           (string-append "installed " smith-plugin-name)))])))

;;@doc
;; Ensure a plugin is installed and loaded. This is intended for init.scm.
(define (smith-ensure source [name #false] [entry #false] [branch #false])
  (let* ([url (smith-normalize-source source)]
         [known (if name
                    (smith-find-spec name (smith-registry))
                    (smith-find-spec-by-source url (smith-registry)))]
         [label (or name source)])
    (when known (smith-declare-plugin! (smith-plugin-name known)))
    (with-handler
      (lambda (err)
        (let ([message (string-append "plugin install skipped: " label ": " (to-string err))])
          (helix.misc.set-warning! message)
          message))
      (let ([result (smith-install source name entry branch)]
            [installed (if name
                           (smith-find-spec name (smith-registry))
                           (smith-find-spec-by-source url (smith-registry)))])
        (when installed (smith-declare-plugin! (smith-plugin-name installed)))
        result))))

;;@doc
;; Evaluate configuration forms after a plugin has been installed and loaded.
(define (smith-configure! name forms)
  (if (path-exists? (smith-plugin-path name))
      (with-handler
        (lambda (err)
          (let ([message
                 (string-append "plugin configuration skipped: "
                                name
                                ": "
                                (to-string err))])
            (helix.misc.set-warning! message)
            message))
        (map (lambda (form) (eval-string (to-string form))) forms))
      (let ([message (string-append "plugin configuration skipped: "
                                    name
                                    ": package is not installed")])
        (helix.misc.set-warning! message)
        message)))

(define (smith-configure-source! source forms)
  (let* ([url (smith-normalize-source source)]
         [plugin (smith-find-spec-by-source url (smith-registry))])
    (if plugin
        (smith-configure! (smith-plugin-name plugin) forms)
        (let ([message (string-append "plugin configuration skipped: "
                                      source
                                      ": package is not registered")])
          (helix.misc.set-warning! message)
          message))))

;; Declare, install, load, and configure a plugin in one init.scm block.
;; The tuple is (source package-name entry-file) or
;; (source package-name entry-file revision).
(define-syntax smith-declare-plugin
  (syntax-rules ()
    [(smith-declare-plugin (source name entry branch) form ...)
     (begin
       (smith-ensure source name entry branch)
       (smith-configure! name '(form ...)))]
    [(smith-declare-plugin (source name entry) form ...)
     (begin
       (smith-ensure source name entry)
       (smith-configure! name '(form ...)))]
    [(smith-declare-plugin source form ...)
     (begin
       (smith-ensure source)
       (smith-configure-source! source '(form ...)))]))

(define (smith-string-list? values)
  (cond
    [(null? values) #true]
    [(string? (car values)) (smith-string-list? (cdr values))]
    [else #false]))

(define (smith-nested-binding keys command)
  (if (null? (cdr keys))
      (hash (car keys) command)
      (hash (car keys) (smith-nested-binding (cdr keys) command))))

(define (smith-apply-binding! binding)
  (unless (and (list? binding)
               (= (length binding) 3)
               (string? (list-ref binding 0))
               (list? (list-ref binding 1))
               (not (null? (list-ref binding 1)))
               (smith-string-list? (list-ref binding 1))
               (or (string? (list-ref binding 2))
                   (symbol? (list-ref binding 2))))
    (error
      (string-append
        "invalid Smith binding: "
        (to-string binding)
        "; expected (mode (key ...) command)")))
  (keymaps.add-global-keybinding
    (hash (list-ref binding 0)
          (smith-nested-binding (list-ref binding 1)
                                (list-ref binding 2)))))

;; Register declarative global bindings without evaluating the keymap macro.
;; Each binding is (mode (key ...) command), for example
;; '("normal" ("space" "e") ":forest-open").
(define (smith-apply-bindings! bindings)
  (for-each smith-apply-binding! bindings)
  (string-append "registered "
                 (to-string (length bindings))
                 " Smith keybindings"))

;; Expand normalized phases. Init forms stay as syntax in the caller's
;; environment; config forms become data for delayed evaluation after loading.
(define-syntax smith-plugin-phases
  (syntax-rules ()
    [(smith-plugin-phases spec (init-form ...) (config-form ...) ())
     (begin
       init-form ...
       (smith-declare-plugin spec config-form ...))]
    [(smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))
     (begin
       init-form ...
       (smith-declare-plugin spec config-form ...)
       (smith-apply-bindings! '(binding ...)))]))

;;@doc
;; Declare a plugin using separate initialization, post-load configuration, and
;; binding phases. Clauses may appear in any order. Forms in (init ...) run in
;; the caller's environment before installation/loading; forms in (config ...)
;; are evaluated after loading; (bind ...) accepts declarative global bindings.
(define-syntax smith-plugin
  (syntax-rules (init config bind)
    [(smith-plugin spec
                   (init init-form ...)
                   (config config-form ...)
                   (bind binding ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec
                   (init init-form ...)
                   (bind binding ...)
                   (config config-form ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec
                   (config config-form ...)
                   (init init-form ...)
                   (bind binding ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec
                   (config config-form ...)
                   (bind binding ...)
                   (init init-form ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec
                   (bind binding ...)
                   (init init-form ...)
                   (config config-form ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec
                   (bind binding ...)
                   (config config-form ...)
                   (init init-form ...))
     (smith-plugin-phases spec
                          (init-form ...)
                          (config-form ...)
                          (binding ...))]
    [(smith-plugin spec (init init-form ...) (config config-form ...))
     (smith-plugin-phases spec (init-form ...) (config-form ...) ())]
    [(smith-plugin spec (config config-form ...) (init init-form ...))
     (smith-plugin-phases spec (init-form ...) (config-form ...) ())]
    [(smith-plugin spec (init init-form ...) (bind binding ...))
     (smith-plugin-phases spec (init-form ...) () (binding ...))]
    [(smith-plugin spec (bind binding ...) (init init-form ...))
     (smith-plugin-phases spec (init-form ...) () (binding ...))]
    [(smith-plugin spec (config config-form ...) (bind binding ...))
     (smith-plugin-phases spec () (config-form ...) (binding ...))]
    [(smith-plugin spec (bind binding ...) (config config-form ...))
     (smith-plugin-phases spec () (config-form ...) (binding ...))]
    [(smith-plugin spec (init init-form ...))
     (smith-plugin-phases spec (init-form ...) () ())]
    [(smith-plugin spec (config config-form ...))
     (smith-plugin-phases spec () (config-form ...) ())]
    [(smith-plugin spec (bind binding ...))
     (smith-plugin-phases spec () () (binding ...))]
    [(smith-plugin spec)
     (smith-plugin-phases spec () () ())]))

;;@doc
;; Remove every manager-owned Forge package not declared by smith-ensure during
;; the current init.scm evaluation. Other Forge packages are never touched.
(define (smith-prune)
  (let ([stale (filter (lambda (plugin)
                         (not (member (smith-plugin-name plugin) *smith-declared-plugin-names*)))
                       (smith-registry))])
    (if (null? stale)
        "No undeclared plugins"
        (string-join
          (map (lambda (plugin) (smith-remove (smith-plugin-name plugin))) stale)
          "\n"))))

;; Load declared plugins. With the default 'auto mode, undeclared manager-owned
;; packages are removed when init.scm contains at least one smith-ensure call.
;; Pass #true or #false to explicitly enable or disable pruning.
(define (smith-init [prune? 'auto])
  (with-handler
    (lambda (err)
      (let ([message (string-append "smith init failed: " (to-string err))])
        (helix.misc.set-warning! message)
        message))
    (let ([should-prune? (if (equal? prune? 'auto)
                             (not (null? *smith-declared-plugin-names*))
                             prune?)])
      (let ([prune-result (if should-prune? (smith-prune) #false)]
          [load-result
           (if (null? *smith-declared-plugin-names*)
               (smith-load-all)
               (smith-load-enabled
                 (filter (lambda (plugin)
                           (member (smith-plugin-name plugin) *smith-declared-plugin-names*))
                         (smith-registry))))])
      (if prune-result
          (string-append prune-result "\n"
                         (if (list? load-result)
                             (if (null? load-result)
                                 "No enabled plugins"
                                 (string-join load-result "\n"))
                             load-result))
          (if (list? load-result)
              (if (null? load-result)
                  "No enabled plugins"
                  (string-join load-result "\n"))
              load-result))))))

;;@doc
;; Update this manager through Forge. The current Steel engine keeps the loaded
;; definitions until the configuration is reloaded.
(define (smith-self-update [ignored #false])
  (let ([manager (smith-make-plugin "smith.hx"
                              *smith-source*
                              "smith.scm"
                              #false
                              #true)])
    (smith-forge-install! manager #true)
    "updated smith.hx; restart Helix or reload Steel configuration"))

(define (smith-commit plugin)
  (trim (smith-run-command "git"
                           (list "rev-parse" "HEAD")
                           (smith-plugin-directory plugin))))

(define (smith-lock-entry plugin)
  (list (smith-plugin-name plugin)
        (smith-plugin-source plugin)
        (smith-plugin-entry plugin)
        (smith-plugin-enabled? plugin)
        (smith-commit plugin)))

;;@doc
;; Write the exact installed commit of every Smith-managed plugin.
(define (smith-lock [path #false])
  (let* ([target (or path (smith-lock-path))]
         [entries (map smith-lock-entry (smith-registry))]
         [port (open-output-file target #:exists 'truncate)])
    (write entries port)
    (display "\n" port)
    (close-port port)
    (string-append "locked "
                   (to-string (length entries))
                   " plugins to "
                   target)))

(define (smith-read-lock path)
  (unless (path-exists? path)
    (error (string-append "Smith lock file not found: " path)))
  (let ([port (open-input-file path)])
    (let ([entries (read port)])
      (close-port port)
      entries)))

(define (smith-restore-entry entry)
  (let* ([name (list-ref entry 0)]
         [source (list-ref entry 1)]
         [plugin-entry (list-ref entry 2)]
         [enabled? (list-ref entry 3)]
         [revision (list-ref entry 4)]
         [plugin (smith-make-plugin name source plugin-entry revision enabled?)])
    (smith-forge-install! plugin #true)
    (smith-run-command "git"
                       (list "checkout" "--detach" revision)
                       (smith-plugin-directory plugin))
    (unless (equal? revision (smith-commit plugin))
      (error (string-append "failed to restore " name " at " revision)))
    plugin))

;;@doc
;; Restore all locked plugins at their exact commits and replace the registry.
(define (smith-restore [path #false])
  (let* ([source (or path (smith-lock-path))]
         [plugins (map smith-restore-entry (smith-read-lock source))])
    (smith-save-registry! plugins)
    (smith-load-enabled plugins)
    (string-append "restored "
                   (to-string (length plugins))
                   " plugins from "
                   source)))

(define (smith-update-spec plugin [dirty-action "ask"])
  (smith-forge-install! plugin #true)
  (string-append "updated " (smith-plugin-name plugin)))

(define (smith-update-all plugins [dirty-action "ask"])
  (string-join
    (map (lambda (plugin) (smith-update-spec plugin dirty-action)) plugins)
    "\n"))

;;@doc
;; Update one plugin by name, or every installed plugin when no name is given.
(define (smith-update [name #false] [dirty-action "ask"])
  (let ([plugins (smith-registry)])
    (if name
        (let ([plugin (smith-find-spec name plugins)])
          (unless plugin (error (string-append "unknown plugin: " name)))
          (smith-update-spec plugin dirty-action))
        (if (null? plugins)
            "No plugins installed"
            (smith-update-all plugins dirty-action)))))

;;@doc
;; Remove a plugin from the registry and uninstall its Forge package by default.
(define (smith-remove name [delete-files? #true])
  (let* ([plugins (smith-registry)]
         [plugin (smith-find-spec name plugins)])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (when (and delete-files? (path-exists? (smith-plugin-path name)))
      (smith-run-forge (list "pkg" "uninstall" name)))
    (smith-save-registry! (smith-remove-spec name plugins))
    (string-append "removed " name)))

(define (smith-set-enabled! name enabled?)
  (let* ([plugins (smith-registry)]
         [plugin (smith-find-spec name plugins)])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (let ([updated (smith-make-plugin (smith-plugin-name plugin)
                                (smith-plugin-source plugin)
                                (smith-plugin-entry plugin)
                                (smith-plugin-branch plugin)
                                enabled?)])
      (smith-save-registry! (smith-replace-spec updated plugins))
      updated)))

;;@doc
;; Enable a plugin for future `smith-load-all` calls.
(define (smith-enable name)
  (let ([plugin (smith-set-enabled! name #true)])
    (smith-load-spec plugin)
    (string-append "enabled " name)))

;;@doc
;; Disable a plugin for future `smith-load-all` calls. This does not unload code
;; already evaluated in the current Steel engine.
(define (smith-disable name)
  (smith-set-enabled! name #false)
  (string-append "disabled " name))

;;@doc
;; Load one installed plugin by name.
(define (smith-load name)
  (let ([plugin (smith-find-spec name (smith-registry))])
    (unless plugin (error (string-append "unknown plugin: " name)))
    (smith-load-spec plugin)))

(define (smith-load-enabled plugins)
  (cond
    [(null? plugins) '()]
    [(smith-plugin-enabled? (car plugins))
     (cons (smith-load-spec (car plugins)) (smith-load-enabled (cdr plugins)))]
    [else (smith-load-enabled (cdr plugins))]))

;;@doc
;; Load every enabled plugin from the registry. Put this in init.scm for startup loading.
(define (smith-load-all)
  (let ([loaded (smith-load-enabled (smith-registry))])
    (if (null? loaded)
        "No enabled plugins"
        (string-join loaded "\n"))))

(define (smith-spec->line plugin)
  (string-append (smith-plugin-name plugin)
                 " ["
                 (if (smith-plugin-enabled? plugin) "enabled" "disabled")
                 "] "
                 (smith-plugin-source plugin)
                 " -> "
                 (smith-plugin-entry plugin)))

;;@doc
;; Show installed plugins.
(define (smith-list)
  (let ([plugins (smith-registry)])
    (if (null? plugins)
        "No plugins installed"
        (string-join (map smith-spec->line plugins) "\n"))))
