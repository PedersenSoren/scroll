package observability

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"time"

	// Enable the pprof
	_ "net/http/pprof"

	"github.com/gin-contrib/pprof"
	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/scroll-tech/go-ethereum/log"
	"github.com/urfave/cli/v2"
	"gorm.io/gorm"

	"scroll-tech/common/utils"
)

// Server starts the metrics server on the given address, will be closed when the given
// context is canceled.
func Server(c *cli.Context, db *gorm.DB) {
	if !c.Bool(utils.MetricsEnabled.Name) {
		log.Info("Metrics are disabled")
		return
	}

	address := fmt.Sprintf(":%s", c.String(utils.MetricsPort.Name))
	r := setupRouter(db)
	server := &http.Server{
		Addr:              address,
		Handler:           r,
		ReadHeaderTimeout: time.Minute,
	}

	log.Info("Starting metrics server", "address", address)

	// Channel to listen for OS signals
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)

	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Crit("Run metrics HTTP server failure", "error", err)
		}
	}()

	<-stop
	log.Info("Shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Error("Server forced to shutdown", "error", err)
	} else {
		log.Info("Server exiting")
	}
}

// setupRouter configures the HTTP router with necessary routes and middleware.
func setupRouter(db *gorm.DB) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery())
	pprof.Register(r)

	r.GET("/metrics", gin.WrapH(promhttp.Handler()))

	probeController := NewProbesController(db)
	r.GET("/health", probeController.HealthCheck)
	r.GET("/ready", probeController.Ready)

	return r
}

// NewProbesController initializes a new ProbesController.
func NewProbesController(db *gorm.DB) *ProbesController {
	return &ProbesController{db: db}
}

// ProbesController handles liveness and readiness probes.
type ProbesController struct {
	db *gorm.DB
}

// HealthCheck handles the liveness probe.
func (p *ProbesController) HealthCheck(c *gin.Context) {
	if err := p.db.DB().Ping(); err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "unhealthy"})
	} else {
		c.JSON(http.StatusOK, gin.H{"status": "healthy"})
	}
}

// Ready handles the readiness probe.
func (p *ProbesController) Ready(c *gin.Context) {
	// Implement additional readiness checks if needed.
	c.JSON(http.StatusOK, gin.H{"status": "ready"})
}
