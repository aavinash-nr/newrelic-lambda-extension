package checks

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/newrelic/newrelic-lambda-extension/config"
	"github.com/newrelic/newrelic-lambda-extension/lambda/extension/api"
	"github.com/newrelic/newrelic-lambda-extension/util"
)

type handlerConfigs struct {
	handlerName string
	conf        *config.Configuration
}

var handlerPath = "/var/task"

func handlerCheck(ctx context.Context, conf *config.Configuration, reg *api.RegistrationResponse, r runtimeConfig) error {
	if r.language != "" {
		h := handlerConfigs{
			handlerName: reg.Handler,
			conf:        conf,
		}

		if !r.check(h) {
			return fmt.Errorf("missing handler file %s (NEW_RELIC_LAMBDA_HANDLER=%s)", h.handlerName, conf.NRHandler)
		}
	}

	return nil
}

func isDocker() bool {
	aws_runtime := strings.ToLower(os.Getenv("AWS_EXECUTION_ENV"))
	return !strings.HasPrefix(aws_runtime, "aws_lambda")
}

func (r runtimeConfig) check(h handlerConfigs) bool {
	if !h.conf.TestingOverride {
		esm := strings.ToLower(os.Getenv("NEW_RELIC_USE_ESM"))
		if esm == "true" {
			return true
		}
		if isDocker() {
			return true
		}
	}
	functionHandler := r.getTrueHandler(h)
	var p string
	if r.language == Node {
		p = removePathMethodNameNode(functionHandler)
		pJS := pathFormatter(p, "js")
		cJS := pathFormatter(p, "cjs")
		pMJS := pathFormatter(p, "mjs")

		if util.PathExists(pJS) || util.PathExists(pMJS) || util.PathExists(cJS) {
			return true
		}
	} else {
		p = removePathMethodName(functionHandler)
		p = pathFormatter(p, r.fileType)
	}
	return util.PathExists(p)
}

func (r runtimeConfig) getTrueHandler(h handlerConfigs) string {
	if !h.conf.TestingOverride {
		esm := strings.ToLower(os.Getenv("NEW_RELIC_USE_ESM"))
		if esm == "true" {
			return h.handlerName
		}
		if util.PathExists("/.dockerenv") {
			return h.handlerName
		}
	}
	if h.handlerName != r.wrapperName {
		util.Logln("Warning: handler not set to New Relic layer wrapper", r.wrapperName)
		return h.handlerName
	}

	return h.conf.NRHandler
}

func removePathMethodName(p string) string {
	s := strings.Split(p, ".")
	return strings.Join(s[:len(s)-1], "/")
}

func removePathMethodNameNode(p string) string {
	mh := filepath.Base(p)
	mr := p[0:strings.Index(p, mh)]

	s := strings.Split(mh, ".")
	m := s[0]

	return filepath.Join(mr, m)
}

func pathFormatter(functionHandler string, fileType string) string {
	p := fmt.Sprintf("%s/%s.%s", handlerPath, functionHandler, fileType)
	return p
}
